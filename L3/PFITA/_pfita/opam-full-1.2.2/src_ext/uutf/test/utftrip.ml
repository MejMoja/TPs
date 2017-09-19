(*---------------------------------------------------------------------------
   Copyright 2012 Daniel C. Bünzli. All rights reserved.
   Distributed under the BSD3 license, see license at the end of the file.
   uutf version 0.9.3
  ---------------------------------------------------------------------------*)

let pp = Format.fprintf
let pp_pos ppf d = pp ppf "%d.%d:(%d) " 
  (Uutf.decoder_line d) (Uutf.decoder_col d) (Uutf.decoder_count d)

let pp_decode inf d ppf v = pp ppf "%s:%a%a@\n" inf pp_pos d Uutf.pp_decode v

let exec = Filename.basename Sys.executable_name
let log f = Format.eprintf ("%s: " ^^ f ^^ "@?") exec 
let log_malformed inf d v = log "%a" (pp_decode inf d) v
    
(* IO tools  *)

let io_buffer_size = 65536                          (* IO_BUFFER_SIZE 4.0.0 *)
let unix_buffer_size = 65536                      (* UNIX_BUFFER_SIZE 4.0.0 *)

let rec unix_read fd s j l = try Unix.read fd s j l with 
| Unix.Unix_error (Unix.EINTR, _, _) -> unix_read fd s j l

let rec unix_write fd s j l = 
  let rec write fd s j l = try Unix.single_write fd s j l with 
  | Unix.Unix_error (Unix.EINTR, _, _) -> write fd s j l
  in
  let wc = write fd s j l in
  if wc < l then unix_write fd s (j + wc) (l - wc) else ()
  
let string_of_channel use_unix ic = 
  let b = Buffer.create unix_buffer_size in 
  let input, s = 
    if use_unix 
    then unix_read (Unix.descr_of_in_channel ic), String.create unix_buffer_size
    else input ic, String.create io_buffer_size 
  in
  let rec loop b input s = 
    let rc = input s 0 (String.length s) in 
    if rc = 0 then Buffer.contents b else 
    (Buffer.add_substring b s 0 rc; loop b input s)
  in
  loop b input s

let string_to_channel use_unix oc s = 
  if use_unix
  then unix_write (Unix.descr_of_out_channel oc) s 0 (String.length s)
  else output_string oc s

let dst_for sout = if sout then `Buffer (Buffer.create 512) else `Channel stdout
let src_for inf sin use_unix =
  try 
    let ic = if inf = "-" then stdin else open_in inf in 
    if sin then `String (string_of_channel use_unix ic) else `Channel ic
  with Sys_error e -> log "%s\n" e; exit 1

let close_src src = 
  try match src with `Channel ic when ic <> stdin -> close_in ic | _ -> () with
  | Sys_error e -> log "%s\n" e; exit 1

let src_for_unix inf = 
  try if inf = "-" then Unix.stdin else Unix.(openfile inf [O_RDONLY] 0) with
  | Unix.Unix_error (e, _, v) -> log "%s: %s\n" (Unix.error_message e) v; exit 1

let close_src_unix fd = try if fd <> Unix.stdin then Unix.close fd with 
| Unix.Unix_error (e, _, v) -> log "%s: %s\n" (Unix.error_message e) v; exit 1

let rec encode_unix fd s e v = match Uutf.encode e v with `Ok -> () 
| `Partial ->
    unix_write fd s 0 (String.length s - Uutf.Manual.dst_rem e); 
    Uutf.Manual.dst e s 0 (String.length s); 
    encode_unix fd s e `Await

(* Dump *) 

let dump_ inf encoding nln src =
  let rec loop inf d = match Uutf.decode d with `Await -> assert false
  | v -> (pp_decode inf d) Format.std_formatter v; if v <> `End then loop inf d
  in
  loop inf (Uutf.decoder ?nln ?encoding src)
    
let dump_unix inf encoding nln usize fd =
  let rec loop fd s d = match Uutf.decode d with
  | `Await -> 
      let rc = unix_read fd s 0 (String.length s) in 
      Uutf.Manual.src d s 0 rc; loop fd s d
  | v -> (pp_decode inf d) Format.std_formatter v; if v <> `End then loop fd s d
  in
  loop fd (String.create usize) (Uutf.decoder ?nln ?encoding `Manual) 

let dump inf sin use_unix usize ie nln = 
  if sin || not use_unix then dump_ inf ie nln (src_for inf sin use_unix) else 
  dump_unix inf ie nln usize (src_for_unix inf)

(* Guess only *)

let guess inf = 
  let d = Uutf.decoder (src_for inf false false) in 
  ignore (Uutf.decode d); 
  Format.printf "%s@." (Uutf.encoding_to_string (Uutf.decoder_encoding d))

(* Decode only *)

let decode_ inf encoding nln src =
  let malformed = log_malformed inf in 
  let rec loop d = match Uutf.decode d with `Await -> assert false
  | `Uchar _ -> loop d
  | `End -> ()
  | `Malformed _ as v -> malformed d v; loop d
  in
  loop (Uutf.decoder ?nln ?encoding src); close_src src

let decode_unix inf encoding nln usize fd =
  let malformed = log_malformed inf in
  let rec loop fd s d = match Uutf.decode d with
  | `Uchar _ -> loop fd s d
  | `End -> () 
  | `Malformed _ as v -> malformed d v; loop fd s d
  | `Await -> 
      let rc = unix_read fd s 0 (String.length s) in 
      Uutf.Manual.src d s 0 rc; loop fd s d
  in
  loop fd (String.create usize) (Uutf.decoder ?nln ?encoding `Manual); 
  close_src_unix fd

let decode inf sin use_unix usize ie nln =
  if sin || not use_unix then decode_ inf ie nln (src_for inf sin use_unix) else
  decode_unix inf ie nln usize (src_for_unix inf)
  
(* Random encode only *)

let u_surrogate_count = 0xDFFF - 0xD800 + 1
let uchar_count = (0x10FFFF + 1) - u_surrogate_count
let r_uchar () = 
  let n = Random.int uchar_count in
  if n > 0xD7FF then n + u_surrogate_count else n
  
let r_text encoding encode_f rcount = 
  encode_f (`Uchar Uutf.u_bom);
  for i = 1 to rcount do encode_f (`Uchar (r_uchar ())) done;
  encode_f `End

let encode_f encoding dst = 
  let e = Uutf.encoder encoding dst in
  fun v -> match Uutf.encode e v with `Ok -> () | `Partial -> assert false 
          
let encode_f_unix usize encoding fd =
  let e, s = Uutf.encoder encoding `Manual, String.create usize in
  Uutf.Manual.dst e s 0 (String.length s);
  encode_unix fd s e

let r_encode sout use_unix usize rseed rcount oe = 
  let dst = dst_for sout in
  let oe = match oe with None -> `UTF_8 | Some enc -> enc in
  let encode_f = 
    if sout || not use_unix then encode_f oe dst else
    encode_f_unix usize oe Unix.stdout
  in 
  log "Encoding %d random characters with seed %d\n" rcount rseed;
  Random.init rseed; r_text oe encode_f rcount;
  match dst with `Channel _ -> ()
  | `Buffer b -> string_to_channel use_unix stdout (Buffer.contents b)
  
(* Trip *)
    
let trip_ inf nln ie oe src dst = 
  let malformed = log_malformed inf in
  let rec loop d e = function `Await -> assert false
  | `Uchar _ as v -> ignore (Uutf.encode e v); loop d e (Uutf.decode d)
  | `End -> ignore (Uutf.encode e `End)
  | `Malformed _ as v -> malformed d v; loop d e (Uutf.decode d)
  in
  let d = Uutf.decoder ?nln ?encoding:ie src in 
  let e, first = match oe with 
  | Some enc -> Uutf.encoder enc dst, (Uutf.decode d)
  | None ->
      let v = Uutf.decode d in                          (* get the encoding. *)
      let enc = match Uutf.decoder_encoding d with 
      | #Uutf.encoding as enc -> enc | `ISO_8859_1 | `US_ASCII -> `UTF_8
      in
      Uutf.encoder enc dst, v
  in
  if (Uutf.encoder_encoding e = `UTF_16 || Uutf.decoder_removed_bom d) 
  then ignore (Uutf.encode e (`Uchar Uutf.u_bom));
  loop d e first; close_src src

let trip_unix inf usize nln ie oe fdi fdo =
  let malformed = log_malformed inf in
  let rec loop fdi fdo ds es d e = function
  | `Uchar _ as v ->
      encode_unix fdo es e v; loop fdi fdo ds es d e (Uutf.decode d)
  | `End -> encode_unix fdo es e `End
  | `Malformed _ as v -> malformed d v; loop fdi fdo ds es d e (Uutf.decode d)
  | `Await -> 
      let rc = unix_read fdi ds 0 (String.length ds) in 
      Uutf.Manual.src d ds 0 rc; loop fdi fdo ds es d e (Uutf.decode d)
  in
  let d, ds = Uutf.decoder ?nln ?encoding:ie `Manual, String.create usize in
  let e, es, first = match oe with 
  | Some enc -> Uutf.encoder enc `Manual, String.create usize, (Uutf.decode d)
  | None -> 
      let rec decode_past_await d = match Uutf.decode d with 
      | `Await -> 
          let rc = unix_read fdi ds 0 (String.length ds) in 
          Uutf.Manual.src d ds 0 rc; decode_past_await d
      | v -> v
      in
      let v = decode_past_await d in                        (* get encoding. *)
      let enc = match Uutf.decoder_encoding d with 
      | #Uutf.encoding as enc -> enc | `ISO_8859_1 | `US_ASCII -> `UTF_8
      in
      Uutf.encoder enc `Manual, String.create usize, v  
  in
  Uutf.Manual.dst e es 0 (String.length es); 
  if (Uutf.encoder_encoding e = `UTF_16 || Uutf.decoder_removed_bom d) 
  then encode_unix fdo es e (`Uchar Uutf.u_bom); 
  loop fdi fdo ds es d e first; close_src_unix fdi

let trip inf sin sout use_unix usize ie oe nln = 
  let src = src_for inf sin use_unix in
  let dst = dst_for sout in
  if sin || sout || not use_unix then trip_ inf nln ie oe src dst else
  trip_unix inf usize nln ie oe (src_for_unix inf) Unix.stdout; 
  match dst with `Channel _ -> ()
  | `Buffer b -> string_to_channel use_unix stdout (Buffer.contents b)

let main () = 
  let usage = Printf.sprintf 
    "Usage: %s [OPTION]... [INFILE]\n\
    \ Recode UTF-{8,16,16LE,16BE} from stdin to stdout.\n\
    \ If no input encoding is specified, it is guessed. If no output encoding\n\
    \ is specified, the input encoding is used.\n\
         Options:" exec
  in
  let cmd = ref `Trip in
  let set_cmd v () = cmd := v in
  let inf = ref "-" in
  let set_inf f = 
    if !inf <> "-" then raise (Arg.Bad "only one file can be specified") else
    inf := f 
  in
  let ie = ref None in 
  let ie_fun e = match Uutf.encoding_of_string e with
  | Some e -> ie := Some e 
  | None -> log "unsupported input encoding '%s', trying to guess.\n" e
  in
  let oe = ref None in 
  let oe_fun e = match Uutf.encoding_of_string e with
  | None | Some (`US_ASCII | `ISO_8859_1) -> 
    log "unsupported output encoding '%s', using UTF-8\n" e; oe := Some `UTF_8
  | (Some #Uutf.encoding) as enc -> oe := enc
  in
  let nln = ref None in
  let nln_fun s = match String.lowercase s with
  | "ascii" -> nln := Some (`ASCII 0x000A)
  | "nlf" -> nln := Some (`NLF 0x000A)
  | "readline" -> nln := Some (`Readline 0x000A)
  | n -> log "unknown line normalization (%s), won't normalize" n
  in
  let sin = ref false in
  let sout = ref false in
  let use_unix = ref false in
  let usize = ref unix_buffer_size in 
  let rseed = ref (Random.self_init (); Random.int (1 lsl 30 - 1)) in
  let rcount = ref 1_000_000 in
  let nat s r v = if v > 0 then r := v else log "%s must be > 0, ignored\n" s in
  let options = [
    "-dump", Arg.Unit (set_cmd `Dump), 
    " Dump scalar values in ASCII with their position, one per line";
    "-guess", Arg.Unit (set_cmd `Guess), " Only guess the encoding";
    "-dec", Arg.Unit (set_cmd `Decode), " Decode only, no encoding"; 
    "-enc", Arg.Unit (set_cmd `Encode), " Encode only (random), no decoding";
    "-ie", Arg.String ie_fun,
    "<enc> Input encoding: UTF-8, UTF-16, UTF-16BE, UTF-16LE, ASCII, latin1";
    "-oe", Arg.String oe_fun,
    "<enc> Output encoding: UTF-8, UTF-16, UTF-16BE or UTF-16LE";
    "-nln", Arg.String nln_fun,
    "<kind> Newline normalization to U+000A: ASCII, NLF or Readline";
    "-sin", Arg.Set sin, " Input as string and decode the string";
    "-sout", Arg.Set sout, " Encode as string and output the string";
    "-unix", Arg.Set use_unix, " Use Unix IO";
    "-usize", Arg.Int (nat "-usize" usize),
    "<int> Unix IO buffer sizes in bytes";
    "-rseed", Arg.Int (nat "-rseed" rseed), "<int> Random seed"; 
    "-rcount", Arg.Int (nat "-rcount" rcount), 
    "<int> Number of random characters to generate"; ]
  in
  Arg.parse (Arg.align options) set_inf usage;
  match !cmd with 
  | `Dump -> dump !inf !sin !use_unix !usize !ie !nln 
  | `Guess -> guess !inf
  | `Decode -> decode !inf !sin !use_unix !usize !ie !nln
  | `Encode -> r_encode !sout !use_unix !usize !rseed !rcount !oe
  | `Trip -> trip !inf !sin !sout !use_unix !usize !ie !oe !nln
  
let () = main ()

(*---------------------------------------------------------------------------
   Copyright 2012 Daniel C. Bünzli
   All rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions
   are met:
     
   1. Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

   3. Neither the name of Daniel C. Bünzli nor the names of
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  ---------------------------------------------------------------------------*)
