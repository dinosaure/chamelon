(* a block is, physically, a revision count and series of commits *)

type t = {
  revision_count : int32;
  commits : Commit.t list; (* the structure specified is more complex than this, but `list` will do for now *)
}

let empty = {
  revision_count = 0l;
  commits = [];
}

let get_padding is_first program_block_size entries =
  let sizeof_revision_count = 4
  and sizeof_crc = 4 in

  let unpadded_size = 
    (if is_first then sizeof_revision_count else 0)
                                                + (Entry.lenv entries)
                                                + Tag.size
                                                + sizeof_crc
  in
  let overhang = Int32.(rem (of_int unpadded_size) program_block_size) in
  match overhang with
  | 0l -> 0
  | n -> Int32.(sub program_block_size n |> to_int)

let commit ~program_block_size block entries =
  match block.commits with
  | [] ->
    let padding = get_padding true program_block_size entries in
    { block with commits = [{ entries;
                              padding;
                            }]
    }
  | l ->
    let padding = get_padding false program_block_size entries in
    let commit = Commit.{entries; padding} in
    let commits = List.(rev @@ (commit :: (rev l))) in
    {block with commits; }

(* TODO: ugh, what if we need >1 block for the entries :( *)
let into_cstruct cs block =
  let sizeof_crc = 4 in
  let ffffffff = Cstruct.of_string "\xff\xff\xff\xff" in
  let start_crc = Checkseum.Crc32.default in
  Cstruct.LE.set_uint32 cs 0 block.revision_count;
  let revision_count_crc = Checkseum.Crc32.(digest_bigstring
              (Cstruct.to_bigarray cs) 0 sizeof_crc start_crc)
  in
  (* hey hey, ho ho, we don't want no overflow *)
  let revision_count_crc = Optint.((logand) revision_count_crc
                                     (of_int32 0xffffffffl)) in
  match block.commits with
  | [] -> (* this is a somewhat degenerate case, but
             not pathological enough to throw an error IMO.
             Since there's nothing to write, write nothing *)
    ()
  | _ ->
    let _after_last_crc, _last_tag, _last_crc = List.fold_left
        (fun (pointer, starting_xor_tag, preceding_crc) commit ->
           let last_tag_of_commit =
             Commit.into_cstruct ~next_commit_valid:true ~starting_xor_tag ~preceding_crc
               (Cstruct.shift cs pointer) commit
           in
           (* we never want to pass a CRC *forward* into the next commit. *)
           (pointer + Commit.sizeof commit, last_tag_of_commit, Checkseum.Crc32.default)
        ) (4, ffffffff, revision_count_crc) block.commits in
    ()

let to_cstruct ~block_size block =
  let cs = Cstruct.create block_size in
  let crc = into_cstruct cs block in
  cs, crc

let of_cstruct ~program_block_size block =
  let pbs_int = Int32.to_int program_block_size in
  let revision_count = Cstruct.LE.get_uint32 block 0 in
  let commits = Commit.of_cstructv ~program_block_size:pbs_int (Cstruct.shift block 4) in
  {revision_count; commits}
