let magic = "littlefs"
(* for whatever bonkers reason, the major/minor versions
 * are big-endian, not little-endian like everything else,
 * even though they're not part of a tag and the functions writing
 * them in the reference implementations are little-endian functions --
 * they're defined as full hex values and then written nibble-by-nibble *)
let version = (2, 0) (* major = 2, minor = 0 *)
let name_length_max = 32l (* apparently this is limited to 1022 *)
let file_size_max = 2147483647l (* according to lfs.h in littlefs reference implementation, this is the largest value that will not cause problems with functions that take signed 32-bit integers *)
let file_attribute_size_max = 1022l (* reference implementation comments on this limit *)

type superblock = {
  version_minor : Cstruct.uint16;
  version_major : Cstruct.uint16;
  block_size : Cstruct.uint32;
  block_count : Cstruct.uint32;
  name_length_max : Cstruct.uint32;
  file_size_max : Cstruct.uint32;
  file_attribute_size_max : Cstruct.uint32;
}

[%%cstruct
  type superblock = {
    version_minor : uint16_t;
    version_major : uint16_t;
    block_size : uint32_t;
    block_count : uint32_t;
    name_length_max : uint32_t;
    file_size_max : uint32_t;
    file_attribute_size_max : uint32_t;
  } [@@little_endian]]

let parse cs =
  {
    version_minor = get_superblock_version_minor cs;
    version_major = get_superblock_version_major cs;
    block_size = get_superblock_block_size cs;
    block_count = get_superblock_block_count cs;
    name_length_max = get_superblock_name_length_max cs;
    file_size_max = get_superblock_file_size_max cs;
    file_attribute_size_max = get_superblock_file_attribute_size_max cs;
  }

let into_cstruct cs sb =
  set_superblock_version_minor cs sb.version_minor;
  set_superblock_version_major cs sb.version_major;
  set_superblock_block_size cs sb.block_size;
  set_superblock_block_count cs sb.block_count;
  set_superblock_name_length_max cs sb.name_length_max;
  set_superblock_file_size_max cs sb.file_size_max;
  set_superblock_file_attribute_size_max cs sb.file_attribute_size_max

let to_cstruct sb =
  let cs = Cstruct.create sizeof_superblock in
  into_cstruct cs sb;
  cs

let name =
  let tag = Tag.({
      valid = true;
      type3 = LFS_TYPE_NAME, 0xff;
      id = 0;
      length = 8; })
  in
  (tag, Cstruct.of_string magic)

let inline_struct block_size block_count =
  let entry = {
      version_major = (fst version);
      version_minor = (snd version);
      block_size;
      block_count;
      name_length_max;
      file_size_max;
      file_attribute_size_max;
    } 
  and tag = Tag.({
      valid = true;
      type3 = LFS_TYPE_STRUCT, 0x01;
      id = 0;
      length = sizeof_superblock;
    })
  in
  (tag, to_cstruct entry)
