open Ast
open Lex
open Parser

let _ =
  let gen = Codegen.init () in
  let stream = lex_stream "class Poop extends SuperPoop" in
  let ex =
    try Some (parse_type_def stream) with Parser.Error (kind, _) ->
      print_endline ("Parser Error: " ^ error_msg kind) ;
      None
  in
  let _ = Codegen.uninit gen in
  ()
