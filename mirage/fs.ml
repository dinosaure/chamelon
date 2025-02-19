type blockpair = int64 * int64
type directory_head = blockpair

let root_pair = (0L, 1L)

let pp_blockpair = Fmt.(pair ~sep:comma int64 int64)

open Lwt.Infix

module Make(Sectors: Mirage_block.S)(Clock : Mirage_clock.PCLOCK) = struct
  module This_Block = Block_ops.Make(Sectors)
  type t = {
    block : This_Block.t;
    block_size : int;
    program_block_size : int;
    lookahead : ([`Before | `After ] * (int64 list)) ref;
    new_block_mutex : Lwt_mutex.t;
  }

  type write_result = [ `No_space | `Split | `Split_emergency ]

  type key = Mirage_kv.Key.t

  let log_src = Logs.Src.create "chamelon-fs" ~doc:"chamelon FS layer"
  module Log = (val Logs.src_log log_src : Logs.LOG)

  (* error type definitions straight outta mirage-kv *)
  type error = [
    | `Not_found           of key (** key not found *)
    | `Dictionary_expected of key (** key does not refer to a dictionary. *)
    | `Value_expected      of key (** key does not refer to a value. *)
  ]
  type write_error = [
    | error
    | `No_space                (** No space left on the device. *)
    | `Too_many_retries of int (** {!batch} has been trying to commit [n] times
                                   without success. *)
  ]

  module Read = struct

    (* get the wodge of data at this block number, and attempt to parse it *)
    let block_of_block_number {block_size; block; program_block_size; _} block_location =
      let cs = Cstruct.create block_size in
      This_Block.read block block_location [cs] >>= function
      | Error b -> Lwt.return @@ Error (`Block b)
      | Ok () ->
        match Chamelon.Block.of_cstruct ~program_block_size cs with
        | Error (`Msg s) ->
          Log.err (fun f -> f "error reading block %Ld : %s"
                      block_location s);
          Lwt.return @@ Error (`Chamelon `Corrupt)
        | Ok extant_block -> Lwt.return @@ Ok extant_block

    (* get the blocks at pair (first, second), parse them, and return whichever is more recent *)
    let block_of_block_pair t (l1, l2) =
      let open Lwt_result.Infix in
      Lwt_result.both (block_of_block_number t l1) (block_of_block_number t l2) >>= fun (b1, b2) ->
      if Chamelon.Block.(compare (revision_count b1) (revision_count b2)) < 0
      then Lwt.return @@ Ok b2
      else Lwt.return @@ Ok b1
          
  end

  module Traverse = struct
    let rec get_ctz_pointers t l index pointer =
      match l, index with
      | Error _ as e, _ -> Lwt.return e
      | Ok l, 1 -> Lwt.return @@ Ok (pointer :: l)
      | Ok l, index ->
        let open Lwt_result.Infix in
        let data = Cstruct.create t.block_size in
        This_Block.read t.block pointer [data] >>= fun ()->
        let pointers, _data_region = Chamelon.File.of_block index data in
        match pointers with
        | [] -> Lwt.return @@ Ok (pointer::l)
        | next::_ -> get_ctz_pointers t (Ok (pointer::l)) (index - 1) (Int64.of_int32 next)

    let rec follow_links t = function
      | Chamelon.Entry.Data (pointer, length) -> begin
          let file_size = Int32.to_int length in
          let index = Chamelon.File.last_block_index ~file_size ~block_size:t.block_size in
          Log.debug (fun f -> f "data block: last block index %d found starting at %ld (0x%lx)" index pointer pointer);
          get_ctz_pointers t (Ok []) index (Int64.of_int32 pointer)
        end
      | Chamelon.Entry.Metadata (a, b) ->
        Read.block_of_block_pair t (a, b) >>= function
        | Error (`Block e) ->
          Logs.err (fun m -> m "error reading block pair %Ld, %Ld (0x%Lx, 0x%Lx): %a"
                       a b a b This_Block.pp_error e);
          Lwt.return @@ Error e
        | Error (`Chamelon `Corrupt) ->
          Logs.err (fun f -> f "filesystem seems corrupted; we couldn't make sense of a block pair");
          Lwt.return @@ Error `Disconnected
        | Ok block ->
          Logs.debug (fun f -> f "finding blocks linked from %a" pp_blockpair (a, b));
          let links = Chamelon.Block.linked_blocks block in
          Lwt_list.fold_left_s (fun so_far link ->
              match so_far with
              | Error _ as e -> Lwt.return e
              | Ok l ->
                follow_links t link >>= function
                | Error e ->
                  Logs.err (fun f -> f "filesystem seems corrupted; we couldn't get a list of unused blocks: %a" This_Block.pp_error e);
                  Lwt.return @@ Error `Disconnected
                | Ok new_links -> Lwt.return @@ Ok (new_links @ l)
            ) (Ok []) links
          >>= function
          | Ok list -> Lwt.return @@ Ok (a :: b :: list)
          | e -> Lwt.return e

    (* [last_block t pair] returns the last blockpair in the hardtail
     * linked list starting at [pair], which may well be [pair] itself *)
    let rec last_block t pair =
      let open Lwt_result.Infix in
      Read.block_of_block_pair t pair >>= fun block ->
      match List.find_opt (fun e ->
          Chamelon.Tag.is_hardtail (fst e)
        ) (Chamelon.Block.entries block) with
      | None -> Lwt.return @@ Ok pair
      | Some entry -> match Chamelon.Dir.hard_tail_links entry with
        | None -> Lwt.return @@ Ok pair
        | Some next_pair -> last_block t next_pair
  end

  module Allocate = struct

    let opp = function
      | `Before -> `After
      | `After -> `Before

    let unused ~bias t l1 =
      let module IntSet = Set.Make(Int64) in
      let possible_blocks = This_Block.block_count t.block in
      let all_indices = IntSet.of_list (List.init possible_blocks (fun a -> Int64.of_int a)) in
      let set1 = IntSet.of_list l1 in
      let candidates = IntSet.diff all_indices set1 in
      let pivot = Int64.(unsigned_div (of_int possible_blocks) 2L) in
      let set = match bias, IntSet.split pivot candidates with
        | `After, (_, true, s) -> IntSet.add pivot s
        | `Before, (s, true, _)
        | `Before, (s, false, _)
        | `After, (_, false, s) -> s
      in
      Logs.debug (fun f -> f "filesystem has %d (0x%x) blocks. of these %d are used and %d available for immediate allocation" possible_blocks possible_blocks (List.length l1) (IntSet.cardinal set));
      IntSet.elements set

    let populate_lookahead t bias =
      Traverse.follow_links t (Chamelon.Entry.Metadata root_pair) >|= function
      | Error e ->
        Log.err (fun f -> f "error attempting to find unused blocks: %a" This_Block.pp_error e);
        Error `No_space
      | Ok used_blocks ->
        Log.debug (fun f -> f "%d blocks used: %a" (List.length used_blocks) Fmt.(list ~sep:sp uint64) used_blocks);
        Ok (unused ~bias t used_blocks)

    let get_block t =
      match !(t.lookahead) with
      | bias, block::l ->
        t.lookahead := bias, l;
        Lwt.return @@ Ok block
      | bias, [] ->
        let open Lwt_result.Infix in
        populate_lookahead t bias >>= function
        | [] ->
          Log.err (fun f -> f "no blocks remain free on filesystem");
          Lwt.return @@ Error `No_space
        | block::l ->
          t.lookahead := (opp bias, l);
          Log.debug (fun f -> f "adding %d blocks to lookahead buffer (%a)" (List.length l) Fmt.(list int64) l);
          Lwt.return @@ Ok block

    (* this is a common enough case that it makes sense to handle it explicitly *)
    let get_block_pair t =
      match !(t.lookahead) with
      | bias, block1::block2::l ->
        t.lookahead := bias, l;
        Lwt.return @@ Ok (block1, block2)
      (* whether we have 1 block left or none, we still need to repopulate the lookahead buffer
       * so go just go ahead and do it first, and then take the first two blocks *)
      | bias, _ ->
        let open Lwt_result.Infix in
        populate_lookahead t bias >>= function
        | block1::block2::l ->
          t.lookahead := (opp bias, l);
          Log.debug (fun f -> f "adding %d blocks to lookahead buffer (%a)" (List.length l) Fmt.(list int64) l);
          Lwt.return @@ Ok (block1, block2)
        | l ->
          Log.debug (fun f -> f "%d unused blocks: %a" (List.length l) Fmt.(list int64) l);
          Log.err (fun f -> f "insufficient free blocks to allocate a new block pair");
          Lwt.return @@ Error `No_space

  end

  module Write = struct
    (* from the littlefs spec, we should be checking whether
     * the on-disk data matches what we have in memory after
     * doing this write. Then if it doesn't, we should rewrite
     * to a different block, and note the block as bad so we don't
     * try to write to it in the future.
     *
     * I don't think that's necessary in our execution context.
     * we're not writing directly to a flash controller,
     * we're probably writing to a file on another filesystem
     * managed by an OS with its own bad block detection.
     * That's my excuse for punting on it for now, anyway. *)
    let block_to_block_number t data block_location : (unit, write_result) result Lwt.t =
      let block_device = t.block in
      This_Block.write block_device block_location [data] >>= function
      | Ok () -> Lwt.return @@ Ok ()
      | Error e ->
        Log.err (fun m -> m "block write error: %a" This_Block.pp_write_error e);
        Lwt.return @@ Error `No_space

    let rec block_to_block_pair t data (b1, b2) : (unit, write_result) result Lwt.t =
      let split data  =
        Allocate.get_block_pair t >>= function
        | Error `No_space -> Lwt.return @@ Error `No_space
        | Ok (new_block_1, new_block_2) when Int64.equal new_block_1 new_block_2 ->
          (* if there is only 1 block remaining, we'll get the same one twice.
           * That's not enough for the split. *)
          Lwt.return @@ Error `No_space
        | Ok (new_block_1, new_block_2) -> begin
            Logs.debug (fun m -> m "splitting block pair %Ld, %Ld to %Ld, %Ld"
                           b1 b2 new_block_1 new_block_2);
            let old_block, new_block = Chamelon.Block.split data (new_block_1, new_block_2) in
            Logs.debug (fun m -> m "keeping %d entries in the old block, and putting %d in the new one"
                           (List.length @@ Chamelon.Block.entries old_block)
                           (List.length @@ Chamelon.Block.entries new_block));
            (* be very explicit about writing the new block first, and only overwriting
             * the old block pair if the new block pair write succeeded *)
            block_to_block_pair t new_block (new_block_1, new_block_2) >>= function
            | Error `Split | Error `Split_emergency | Error `No_space ->
              Lwt.return @@ Error `No_space
            | Ok () -> begin
                Logs.debug (fun f -> f "wrote new pair; overwriting old pair");
                (* ignore any warnings about needing to split, etc *)
                let cs1 = Cstruct.create t.block_size in
                let serialize = Chamelon.Block.into_cstruct ~program_block_size:t.program_block_size in
                let _ = serialize cs1 old_block in
                Lwt_result.both
                  (block_to_block_number t cs1 b1)
                  (block_to_block_number t cs1 b2) >>= function
                | Ok _ -> Lwt.return @@ Ok ()
                | Error _ as e -> Lwt.return e
              end
          end
      in
      let cs1 = Cstruct.create t.block_size in
      let serialize = Chamelon.Block.into_cstruct ~program_block_size:t.program_block_size in
      match serialize cs1 data with
      | `Ok -> begin
        Lwt_result.both
          (block_to_block_number t cs1 b1)
          (block_to_block_number t cs1 b2)
        >>= function
        | Ok _ -> Lwt.return @@ Ok ()
        | Error _ as e -> Lwt.return e
      end
      | `Split | `Split_emergency ->
        (* try a compaction first *)
        Cstruct.memset cs1 0x00;
        let compacted = Chamelon.Block.compact data in
        Logs.debug (fun m -> m "split requested for a block with %d entries. compacted, we had %d"
                       (List.length @@ Chamelon.Block.entries data)
                       (List.length @@ Chamelon.Block.entries compacted)
                   );
        match serialize cs1 compacted, Chamelon.Block.hardtail compacted with
        | `Ok, _ -> begin
            Logs.debug (fun f -> f "compaction was sufficient. Will not split %a" pp_blockpair (b1, b2));
            Lwt_result.both
              (block_to_block_number t cs1 b1)
              (block_to_block_number t cs1 b2)
            >>= function
            | Ok _ -> Lwt.return @@ Ok ()
            | Error _ as e -> Lwt.return e
          end
        | `Split, None | `Split_emergency, None -> begin
            Logs.debug (fun f -> f "compaction was insufficient and the block has no hardtail. Splitting %a" pp_blockpair (b1, b2));
            split compacted
          end
        | `Split, _ -> begin
            Logs.debug (fun f -> f "split needed, but the block's already split. Writing the compacted block");
            Lwt_result.both
              (block_to_block_number t cs1 b1)
              (block_to_block_number t cs1 b2)
            >>= function
            | Ok _ -> Lwt.return @@ Ok ()
            | Error _ as e -> Lwt.return e
          end
        | `Split_emergency, _ ->
          Logs.err (fun f -> f "Couldn't write to block %a" pp_blockpair (b1, b2));
          Lwt.return @@ Error `No_space
  end

  module Find : sig
    type blockwise_entry_list = blockpair * (Chamelon.Entry.t list)

    (** entries in the directory are split up by block,
     * so the caller can distinguish between re-uses of the same ID number
     * when the directory spans multiple block numbers *)
    val all_entries_in_dir : t -> directory_head ->
      (blockwise_entry_list list, error) result Lwt.t

    val entries_of_name : t -> directory_head -> string -> (blockwise_entry_list list,
                                                           [`No_id of key
                                                           | `Not_found of key]
                                                          ) result Lwt.t

    val find_first_blockpair_of_directory : t -> directory_head -> string list ->
      [`Basename_on of directory_head | `No_entry | `No_id of string | `No_structs] Lwt.t

  end = struct
    type blockwise_entry_list = blockpair * (Chamelon.Entry.t list)

    (* nb: all does mean *all* here; the list is returned uncompacted,
     * so the caller may have to compact to avoid reporting on expired state *)
    let rec all_entries_in_dir t block_pair =
      Read.block_of_block_pair t block_pair >>= function
      | Error _ -> Lwt.return @@ Error (`Not_found (Mirage_kv.Key.v "hard_tail"))
      | Ok block ->
        let this_blocks_entries = Chamelon.Block.entries block in
        match Chamelon.Block.hardtail block with
        | None -> Lwt.return @@ Ok [(block_pair, this_blocks_entries)]
        | Some nextpair ->
          all_entries_in_dir t nextpair >>= function
          | Ok entries -> Lwt.return @@ Ok ((block_pair, this_blocks_entries) :: entries)
          | Error _ -> Lwt.return @@ Error (`Not_found (Mirage_kv.Key.v "hard_tail"))

    let entries_of_name t block_pair name =
      let entries_of_id entries id =
        let matches (tag, _) = 0 = compare tag.Chamelon.Tag.id id in
        List.find_all matches entries
      in
      let id_of_key entries key =
        let data_matches c = 0 = String.(compare key @@ Cstruct.to_string c) in
        let tag_matches t = Chamelon.Tag.(fst t.type3 = LFS_TYPE_NAME)
        in
        match List.find_opt (fun (tag, data) ->
            tag_matches tag && data_matches data
          ) entries with
        | Some (tag, _) -> Some tag.Chamelon.Tag.id
        | None -> None
      in
      let open Lwt_result in
      all_entries_in_dir t block_pair >>= fun entries_by_block ->
      let entries_matching_name (block, entries) =
        match id_of_key (Chamelon.Entry.compact entries) name with
        | None ->
          Logs.debug (fun m -> m "id for %s not found in %d entries from %a"
                         name (List.length entries) pp_blockpair block);
          Error (`No_id (Mirage_kv.Key.v name))
        | Some id ->
          Logs.debug (fun m -> m "name %s is associated with id %d on blockpair %a"
                         name id pp_blockpair block);
          let entries = entries_of_id entries id in
          Logs.debug (fun m -> m "found %d entries for id %d in %a"
                         (List.length entries) id pp_blockpair block);
          let compacted = Chamelon.Entry.compact entries in
          Logs.debug (fun m -> m "after compaction, there were %d entries for id %d in %a"
                         (List.length compacted) id pp_blockpair block);
          Ok (block, compacted)
      in
      let blockwise_matches = List.filter_map (fun es ->
          match entries_matching_name es with
          | Ok (_, []) | Error _ -> None
          | Ok (block, l) -> Some (block, l)
        ) entries_by_block in
      Lwt.return (Ok blockwise_matches)

    let rec find_first_blockpair_of_directory t block_pair key =
      match key with
      | [] -> Lwt.return @@ `Basename_on block_pair
      | key::remaining ->
        entries_of_name t block_pair key >>= function
        | Error _ -> Lwt.return @@ `No_id key
        | Ok [] -> Lwt.return @@ `No_id key
        | Ok l ->
          (* just look at the last entry with this name, and get the entries *)
          let l = snd @@ List.(hd @@ rev l) in
          match List.filter_map Chamelon.Dir.of_entry l with
          | [] -> Lwt.return `No_structs
          | next_blocks::_ ->
            find_first_blockpair_of_directory t next_blocks remaining

  end

  let rec mkdir t parent_blockpair key =
    (* mkdir has its own function for traversing the directory structure
     * because we want to make anything that's missing along the way,
     * rather than having to get an error, mkdir, get another error, mkdir... *)
    let follow_directory_pointers t block_pair = function
      | [] -> begin
        Traverse.last_block t block_pair >>= function
        | Ok pair -> Lwt.return @@ `New_writes_to pair
        | Error _ ->
          Log.err (fun f -> f "error finding last block from blockpair %Ld, %Ld"
                      (fst block_pair) (snd block_pair));
          Lwt.return @@ `New_writes_to block_pair
      end
      | key::remaining ->
        Find.entries_of_name t block_pair key >>= function
        | Error _ -> Lwt.return @@ `Not_found key
        | Ok [] -> Lwt.return `No_structs
        | Ok l ->
          (* we only care about the last block with entries, and don't care
           * which block it is *)
          let l = snd @@ List.(hd @@ rev l) in
          match List.filter_map Chamelon.Dir.of_entry l with
          | [] -> Lwt.return `No_structs
          | next_blocks::_ -> Lwt.return (`Continue (remaining, next_blocks))
    in 
    (* [find_or_mkdir t parent_blockpair dirname] will:
     * attempt to find [dirname] in the directory starting at [parent_blockpair] or any other blockpairs in its hardtail linked list
     * if no valid entries corresponding to [dirname] are found:
        * allocate new blocks for [dirname]
        * find the last blockpair (q, r) in [parent_blockpair]'s hardtail linked list
        * create a directory entry for [dirname] in (q, r)
     *)
    let find_or_mkdir t parent_blockpair (dirname : string) =
      follow_directory_pointers t parent_blockpair [dirname] >>= function
      | `Continue (_path, next_blocks) -> Lwt.return @@ Ok next_blocks
      | `New_writes_to next_blocks -> Lwt.return @@ Ok next_blocks
      | `No_structs | `Not_found _ ->
        Lwt_mutex.with_lock t.new_block_mutex @@ fun () ->
        (* for any error case, try making the directory *)
        (* TODO: it's probably wise to put a delete entry first here if we got No_structs
         * or another "something weird happened" case *)
        (* first off, get a block pair for our new directory *)
        Allocate.get_block_pair t >>= function
        | Error _ -> Lwt.return @@ Error (`No_space)
        | Ok (dir_block_0, dir_block_1) ->
          (* first, write empty commits to the new blockpair; if that fails,
           * we want to bail before making any more structure *)
          Write.block_to_block_pair t (Chamelon.Block.of_entries ~revision_count:1 []) (dir_block_0, dir_block_1) >>= function
          | Error _ ->
            Logs.err (fun f -> f "error initializing a directory at a fresh block pair (%Ld, %Ld)"
                         dir_block_0 dir_block_1);
            Lwt.return @@ Error `No_space
          | Ok () ->
            (* we want to write the entry for our new subdirectory to
             * the *last* blockpair in the parent directory, so follow
             * all the hardtails *)
            Traverse.last_block t parent_blockpair >>= function
            | Error _ -> Lwt.return @@ Error (`Not_found dirname)
            | Ok last_pair_in_dir ->
              Logs.debug (fun f -> f "found last pair %a in directory starting at %a"
                             pp_blockpair last_pair_in_dir
                             pp_blockpair parent_blockpair);
              Read.block_of_block_pair t last_pair_in_dir >>= function
              | Error _ -> Lwt.return @@ Error (`Not_found dirname)
              | Ok block_to_write ->
                let extant_ids = Chamelon.Block.ids block_to_write in
                let dir_id = match Chamelon.Block.IdSet.max_elt_opt extant_ids with
                  | None -> 1
                  | Some s -> s + 1
                in
                let name = Chamelon.Dir.name dirname dir_id in
                let dirstruct = Chamelon.Dir.mkdir ~to_pair:(dir_block_0, dir_block_1) dir_id in
                let new_block = Chamelon.Block.add_commit block_to_write [name; dirstruct] in
                Write.block_to_block_pair t new_block last_pair_in_dir >>= function
                | Error _ -> Lwt.return @@ Error `No_space
                | Ok () -> Lwt.return @@ Ok (dir_block_0, dir_block_1)
    in
    match key with
    | [] -> Lwt.return @@ Ok parent_blockpair
    | dirname::more ->
      let open Lwt_result in
      (* finally, the recursive bit: when we've successfully found or made a directory
       * but we have more components in the path,
       * find or make the next component relative to the juts-returned blockpair *)
      find_or_mkdir t parent_blockpair dirname >>= fun newpair ->
      mkdir t newpair more

  module File_read : sig
    val get : t -> Mirage_kv.Key.t -> (string, error) result Lwt.t
  end = struct

    let get_ctz t key (pointer, length) =
      let rec read_block l index pointer =
        let data = Cstruct.create t.block_size in
        This_Block.read t.block pointer [data] >>= function
        | Error _ as e -> Lwt.return e
        | Ok () ->
          let pointers, data_region = Chamelon.File.of_block index data in
          match pointers with
          | next::_ ->
            read_block (data_region :: l) (index - 1) (Int64.of_int32 next)
          | [] ->
            Lwt.return @@ Ok (data_region :: l)
      in
      let index = Chamelon.File.last_block_index ~file_size:length
          ~block_size:t.block_size in
      read_block [] index pointer >>= function
      | Error _ -> Lwt.return @@ Error (`Not_found key)
      | Ok l ->
        (* the last block very likely needs to be trimmed *)
        let cs = Cstruct.sub (Cstruct.concat l) 0 length in
        let s = Cstruct.(to_string cs) in
        Lwt.return @@ Ok s

    let get_value t parent_dir_head filename =
      Find.entries_of_name t parent_dir_head filename >|= function
      | Error _ | Ok [] -> Error (`Not_found filename)
      | Ok compacted ->
        (* if there are >1 block with entries, we only care about the last one *)
        let compacted = snd @@ List.(hd @@ rev compacted) in
        let inline_files = List.find_opt (fun (tag, _data) ->
            Chamelon.Tag.((fst tag.type3) = LFS_TYPE_STRUCT) &&
            Chamelon.Tag.((snd tag.type3) = 0x01)
          )
        in
        let ctz_files = List.find_opt (fun (tag, _block) ->
            Chamelon.Tag.((fst tag.type3 = LFS_TYPE_STRUCT) &&
                          Chamelon.Tag.((snd tag.type3 = 0x02)
                                       ))) in
        Log.debug (fun m -> m "found %d entries with name %s" (List.length compacted) filename);
        match inline_files compacted, ctz_files compacted with
        | Some (_tag, data), None -> Ok (`Inline (Cstruct.to_string data))
        | None, None -> begin
          (* is it actually a directory? *)
            match List.find_opt (fun (tag, _data) ->
                Chamelon.Tag.((fst tag.type3) = LFS_TYPE_STRUCT) &&
                Chamelon.Tag.((snd tag.type3) = 0x00)
              ) compacted with
            | Some _ -> Error (`Value_expected filename)
            | None ->
              Log.debug (fun f -> f "an ID was found for the filename, but no entries are structs or files");
              Error (`Not_found filename)
        end
        | _, Some (_, ctz) ->
          match Chamelon.File.ctz_of_cstruct ctz with
          | Some (pointer, length) -> Ok (`Ctz (Int64.of_int32 pointer, Int32.to_int length))
          | None -> Error (`Value_expected filename)

    let get t key : (string, error) result Lwt.t =
      let map_errors = function
        | Ok (`Inline d) -> Lwt.return (Ok d)
        | Ok (`Ctz ctz) -> get_ctz t key ctz
        | Error (`Not_found k) -> Lwt.return @@ Error (`Not_found (Mirage_kv.Key.v k))
        | Error (`Value_expected k) -> Lwt.return @@ Error (`Value_expected (Mirage_kv.Key.v k))
      in
      match Mirage_kv.Key.segments key with
      | [] -> Lwt.return @@ Error (`Value_expected key)
      | basename::[] -> get_value t root_pair basename >>= map_errors
      | _ ->
        let dirname = Mirage_kv.Key.(parent key |> segments) in
        Find.find_first_blockpair_of_directory t root_pair dirname >>= function
        | `Basename_on pair -> begin
            get_value t pair (Mirage_kv.Key.basename key) >>= map_errors
          end
        | _ -> Lwt.return @@ Error (`Not_found key)

  end

  module File_write : sig
    (** [set_in_directory directory_head t filename data] creates entries in
     * [directory] for [filename] pointing to [data] *)
    val set_in_directory : directory_head -> t -> string -> string ->
      (unit, write_error) result Lwt.t

  end = struct  

    let rec write_ctz_block t l index so_far data =
      if Int.compare so_far (String.length data) >= 0 then begin
        (* we purposely don't reverse the list because we're going to want
         * the *last* block for inclusion in the ctz structure *)
        Lwt.return @@ Ok l
      end else begin
        Allocate.get_block t >>= function
        | Error _ -> Lwt.return @@ Error `No_space
        | Ok block_number ->
          let pointer = Int64.to_int32 block_number in
          let block_cs = Cstruct.create t.block_size in
          let skip_list_size = Chamelon.File.n_pointers index in
          let skip_list_length = skip_list_size * 4 in
          let data_length = min (t.block_size - skip_list_length) ((String.length data) - so_far) in
          (* the 0th item in the skip list is always (index - 1). Only exception
           * is the last block in the list (the first block in the file),
           * which has no skip list *)
          (match l with
           | [] -> ()
           | (_last_index, last_pointer)::_ ->
             (* the first entry in the skip list should be for block _last_index,
              * which is index - 1 *)
             Cstruct.LE.set_uint32 block_cs 0 last_pointer
          );
          for n_skip_list = 1 to (skip_list_size - 1) do
            let point_index = List.assoc (n_skip_list / (2 lsl n_skip_list)) l in
            Cstruct.LE.set_uint32 block_cs (n_skip_list * 4) point_index
          done;
          Cstruct.blit_from_string data so_far block_cs skip_list_length data_length;
          This_Block.write t.block (Int64.of_int32 pointer) [block_cs] >>= function
          | Error _ -> Lwt.return @@ Error `No_space
          | Ok () ->
            write_ctz_block t ((index, pointer)::l) (index + 1) (so_far + data_length) data
      end

    let rec write_in_ctz dir_block_pair t filename data entries =
      Read.block_of_block_pair t dir_block_pair >>= function
      | Error _ -> Lwt.return @@ Error (`Not_found (Mirage_kv.Key.v filename))
      | Ok root ->
        match Chamelon.Block.hardtail root with
        | Some next_blockpair -> write_in_ctz next_blockpair t filename data entries
        | None ->
          let file_size = String.length data in
          write_ctz_block t [] 0 0 data >>= function
          | Error _ as e -> Lwt.return e
          | Ok [] -> Lwt.return @@ Error `No_space
          | Ok ((_last_index, last_pointer)::_) ->
            let next = match Chamelon.Block.(IdSet.max_elt_opt @@ ids root) with
              | None -> 1
              | Some n -> n + 1
            in
            let name = Chamelon.File.name filename next in
            let ctime = Chamelon.Entry.ctime next (Clock.now_d_ps ()) in
            let ctz = Chamelon.File.create_ctz next
                ~pointer:last_pointer ~file_size:(Int32.of_int file_size)
            in
            let new_entries = entries @ [name; ctime; ctz] in
            Logs.debug (fun m -> m "writing ctz %d entries for ctz for file %s" (List.length new_entries) filename);
            let new_block = Chamelon.Block.add_commit root new_entries in
            Write.block_to_block_pair t new_block dir_block_pair >>= function
            | Error `No_space -> Lwt.return @@ Error `No_space
            | Error _ -> Lwt.return @@ Error (`Not_found (Mirage_kv.Key.v filename))
            | Ok () -> Lwt.return @@ Ok ()

    let rec write_inline block_pair t filename data entries =
      Read.block_of_block_pair t block_pair >>= function
      | Error _ ->
        Logs.err (fun m -> m "error reading block pair %Ld, %Ld"
                     (fst block_pair) (snd block_pair));
        Lwt.return @@ Error (`Not_found (Mirage_kv.Key.v filename))
      | Ok extant_block ->
        match Chamelon.Block.hardtail extant_block with
        | Some next_blockpair -> write_inline next_blockpair t filename data entries
        | None ->
          let used_ids = Chamelon.Block.ids extant_block in
          let next = match Chamelon.Block.IdSet.max_elt_opt used_ids with
            | None -> 1
            | Some n -> n + 1
          in
          let ctime = Chamelon.Entry.ctime next (Clock.now_d_ps ()) in
          let file = Chamelon.File.write_inline filename next (Cstruct.of_string data) in
          let commit = entries @ (ctime :: file) in
          Logs.debug (fun m -> m "writing %d entries for inline file %s" (List.length file) filename);
          let new_block = Chamelon.Block.add_commit extant_block commit in
          Write.block_to_block_pair t new_block block_pair >>= function
          | Error `No_space -> Lwt.return @@ Error `No_space
          | Error `Split | Error `Split_emergency ->
            Logs.err (fun m -> m "couldn't write a block, because it got too big");
            Lwt.return @@ Error `No_space
          | Ok () -> Lwt.return @@ Ok ()

    let set_in_directory block_pair t (filename : string) data =
      if String.length filename < 1 then Lwt.return @@ Error (`Value_expected Mirage_kv.Key.empty)
      else begin
        Lwt_mutex.with_lock t.new_block_mutex @@ fun () ->
        Find.entries_of_name t block_pair filename >>= function
        | Error (`Not_found _ ) as e -> Lwt.return e
        | Ok [] | Ok ((_, [])::_) | Error (`No_id _) -> begin
            Logs.debug (fun m -> m "writing new file %s, size %d" filename (String.length data));
            if (String.length data) > (t.block_size / 4) then
              write_in_ctz block_pair t filename data []
            else
              write_inline block_pair t filename data []
          end
        | Ok ((block, hd::_tl)::_) ->
          (* we *could* replace the previous ctz/inline entry,
           * instead of deleting the whole mapping and replacing it,
           * but since we do both the deletion and the new addition
           * in the same commit, I think this saves us some potentially
           * error-prone work *)
          let id = Chamelon.Tag.((fst hd).id) in
          Logs.debug (fun m -> m "deleting existing entry %s at id %d" filename id);
          let delete = (Chamelon.Tag.(delete id), Cstruct.create 0) in
          (* we need to make sure our deletion and new items go in the same block pair as
           * the originals did *)
          if (String.length data) > (t.block_size / 4) then
            write_in_ctz block t filename data [delete]
          else
            write_inline block t filename data [delete]
        (* TODO: we should probably handle separately the case where multiple
         * blocks have entries matching the name in question -- currently we
         * will only handle the first such block (that remains after compaction) *)
      end

  end

  module Delete = struct
    let delete_in_directory directory_head t name =
      Find.entries_of_name t directory_head name >>= function
        (* several "it's not here" cases *)
      | Error (`No_id _) | Error (`Not_found _) ->
        Logs.debug (fun m -> m "no id or nothing found for %s" name);
        Lwt.return @@ Ok ()
      | Ok [] | Ok ((_,[])::_) ->
        Logs.debug (fun m -> m "no entries on %a for %s"
                       pp_blockpair directory_head name);
        Lwt.return @@ Ok ()
      | Ok ((blockpair_with_id, hd::_tl)::_) ->
        let id = Chamelon.Tag.((fst hd).id) in
        Logs.debug (fun m -> m "id %d found for name %s on block %a" id name
                   pp_blockpair blockpair_with_id);
        Read.block_of_block_pair t blockpair_with_id >>= function
        | Error _ -> Lwt.return @@ Error (`Not_found (Mirage_kv.Key.v name))
        | Ok block ->
          Logs.debug (fun m -> m "adding deletion for id %d on block pair %a"
                         id pp_blockpair blockpair_with_id);
          let deletion = Chamelon.Tag.delete id in
          let new_block = Chamelon.Block.add_commit block [(deletion, Cstruct.empty)] in
          Write.block_to_block_pair t new_block blockpair_with_id >>= function
          | Error _ -> Lwt.return @@ Error `No_space
          | Ok () -> Lwt.return @@ Ok ()

  end

  (* `device` should be an already-connected block device *)
  let connect ~program_block_size ~block_size device : (t, error) result Lwt.t =
    This_Block.connect ~block_size device >>= fun block ->
    Logs.debug (fun f -> f "initiating filesystem with block size %d (0x%x)" block_size block_size);
    let first_block = Cstruct.create block_size in
    This_Block.read block 0L [first_block] >>= function
    | Error e ->
      Logs.err (fun f -> f "first block read failed: %a" This_Block.pp_error e);
      Lwt.return @@ Error (`Not_found (Mirage_kv.Key.empty))
    | Ok () ->
      let t = {block; block_size; program_block_size; lookahead = ref (`Before, []); new_block_mutex = Lwt_mutex.create ()} in
      Lwt_mutex.lock t.new_block_mutex >>= fun () ->
      Traverse.follow_links t (Chamelon.Entry.Metadata root_pair) >>= function
      | Error _e ->
        Lwt_mutex.unlock t.new_block_mutex;
        Lwt.fail_with "couldn't get list of used blocks"
      | Ok used_blocks ->
        Logs.debug (fun f -> f "found %d used blocks on block-based key-value store: %a" (List.length used_blocks) Fmt.(list ~sep:sp int64) used_blocks);
        let open Allocate in
        let lookahead = ref (`After, unused ~bias:`Before t used_blocks) in
        Lwt_mutex.unlock t.new_block_mutex;
        Lwt.return @@ Ok {t with lookahead; block; block_size; program_block_size}

  let format ~program_block_size ~block_size (sectors : Sectors.t) :
    (unit, write_error) result Lwt.t =
    This_Block.connect ~block_size sectors >>= fun block ->
    let write_whole_block n b = This_Block.write block n
        [fst @@ Chamelon.Block.to_cstruct ~program_block_size ~block_size b]
    in
    let name = Chamelon.Superblock.name in
    let block_count = This_Block.block_count block in
    let superblock_inline_struct = Chamelon.Superblock.inline_struct (Int32.of_int block_size) (Int32.of_int block_count) in
    let block_0 = Chamelon.Block.of_entries ~revision_count:1 [name; superblock_inline_struct] in
    let block_1 = Chamelon.Block.of_entries ~revision_count:2 [name; superblock_inline_struct] in
    Lwt_result.both
    (write_whole_block (fst root_pair) block_0)
    (write_whole_block (snd root_pair) block_1) >>= function
    | Ok ((), ()) -> Lwt.return @@ Ok ()
    | _ -> Lwt.return @@ Error `No_space

end
