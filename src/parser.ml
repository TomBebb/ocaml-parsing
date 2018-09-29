open Ast
open Token
open Type

type error_kind =
  | Unexpected of token * string
  | Expected of token list * token * string

let error_msg = function
  | Unexpected (got, expected) ->
      "Unexpected " ^ s_token_def got ^ " while parsing " ^ expected
  | Expected (expected, got, name) ->
      "Expected one of "
      ^ String.concat "," (List.map s_token_def expected)
      ^ " but got " ^ s_token_def got ^ "while parsing " ^ name

exception Error of error_kind span

let next_is tks want =
  match Stream.peek tks with Some (def, _) -> def = want | _ -> false

let mk_pos ex first last =
  (ex, {pfile= first.pfile; pmin= first.pmin; pmax= last.pmax})

let mk ex (_, first) (_, last) = mk_pos ex first last

let mk_one def pos = (def, pos)

let expect_ident tks =
  let tk = Stream.next tks in
  match tk with
  | TIdent id, pos -> mk_one id pos
  | def, _ -> raise (Error (mk (Unexpected (def, "identifier")) tk tk))

let expect tks expected name =
  let tk = Stream.next tks in
  let def, pos = tk in
  if not (List.mem def expected) then
    raise (Error (mk (Expected (expected, def, name)) tk tk))
  else pos

let parse_path tks =
  let first, _ = expect_ident tks in
  let parts = Array.of_list [first] in
  while next_is tks TDot do
    let _ = Stream.next tks in
    let part, _ = expect_ident tks in
    parts.(Array.length parts) <- part
  done ;
  let name = parts.(Array.length parts - 1) in
  let parts = Array.sub parts 0 (Array.length parts - 1) in
  (Array.to_list parts, name)

let parse_ty tks =
  let tk = Stream.next tks in
  let def, pos = tk in
  match def with
  | TKPrim p -> TPrim p
  | _ -> raise (Error (mk_one (Unexpected (def, "type")) pos))

let rec parse_expr tks =
  let rec parse_exprs tks term =
    if next_is tks term then []
    else
      let ex = parse_expr tks in
      [ex] @ parse_exprs tks term
  in
  let parse_base_expr tks =
    let first, first_pos = Stream.next tks in
    match first with
    | TIdent id -> mk_one (EIdent id) first_pos
    | TConst c -> mk_one (EConst c) first_pos
    | TKeyword KVar ->
        let name, _ = expect_ident tks in
        let ty =
          if next_is tks TColon then
            Some
              (let _ = Stream.next tks in
               parse_ty tks)
          else None
        in
        let _ = expect tks [TBinOp OpAssign] "variable declaration" in
        let value = parse_expr tks in
        let _, last_pos = value in
        mk_pos (EVar (ty, name, value)) first_pos last_pos
    | TOpenParen ->
        let inner = parse_expr tks in
        let last = expect tks [TCloseParen] "parenthesis" in
        mk_pos (EParen inner) first_pos last
    | TOpenBrace ->
        let exs = parse_exprs tks TCloseBrace in
        let last = expect tks [TCloseBrace] "block" in
        mk_pos (EBlock exs) first_pos last
    | TKeyword KIf ->
        let cond = parse_expr tks in
        let body = parse_expr tks in
        let else_bod =
          if next_is tks (TKeyword KElse) then
            Some
              (let _ = Stream.next tks in
               parse_expr tks)
          else None
        in
        mk_pos (EIf (cond, body, else_bod)) first_pos first_pos
    | _ -> raise (Error (mk_one (Unexpected (first, "expression")) first_pos))
  in
  let rec parse_after_expr base tks =
    match Stream.peek tks with
    | Some (TDot, _) ->
        let _ = Stream.next tks in
        let field = expect_ident tks in
        let name, last = field in
        let _, first = base in
        parse_after_expr (mk_pos (EField (base, name)) first last) tks

    | Some (TBinOp op, _) ->
        let _ = Stream.next tks in
        let other = parse_expr tks in
        parse_after_expr (mk (EBinOp (op, base, other)) base other) tks
    | _ -> base
  in
  let base = parse_base_expr tks in
  parse_after_expr base tks

let parse_member_mod tks =
  match Stream.peek tks with
  | Some (TKeyword KStatic, _) ->
      let _ = Stream.next tks in
      Some MStatic
  | Some (TKeyword KPublic, _) ->
      let _ = Stream.next tks in
      Some MPublic
  | Some (TKeyword KPrivate, _) ->
      let _ = Stream.next tks in
      Some MPrivate
  | _ -> None

let rec parse_member_mods tks mods =
  match parse_member_mod tks with
  | Some md ->
      mods := MemberMods.add md !mods ;
      parse_member_mods tks mods
  | _ -> ()

let rec parse_params tks term =
  if next_is tks term then []
  else
    let name, _ = expect_ident tks in
    let _ = expect tks [TColon] "parameters" in
    let ty = parse_ty tks in
    let param = {pname= name; ptype= ty} in
    if next_is tks TComma then
      let _ = expect tks [TComma] "parameters" in
      param :: parse_params tks term
    else [param]

let parse_member tks =
  let mods = ref MemberMods.empty in
  parse_member_mods tks mods ;
  let tk = Stream.next tks in
  let def, pos = tk in
  match def with
  | TKeyword KFunc ->
      let name, _ = expect_ident tks in
      let _ = expect tks [TOpenParen] "function declaration" in
      let args = parse_params tks TCloseParen in
      let _ = expect tks [TCloseParen] "function declaration" in
      let ret =
        if next_is tks TColon then
          let _ = Stream.next tks in
          parse_ty tks
        else TPrim TVoid
      in
      let ex = parse_expr tks in
      ({mname= name; mkind= MFunc (args, ret, ex); mmods= !mods}, pos)
  | TKeyword KVar ->
      let name, _ = expect_ident tks in
      let ty =
        if next_is tks TColon then
          let _ = Stream.next tks in
          Some (parse_ty tks)
        else None
      in
      let ex =
        if next_is tks (TBinOp OpAssign) then
          let _ = Stream.next tks in
          Some (parse_expr tks)
        else None
      in
      ({mname= name; mkind= MVar (ty, ex); mmods= !mods}, pos)
  | _ -> raise (Error (mk_one (Unexpected (def, "member")) pos))

let rec parse_members tks term =
  if next_is tks term then []
  else
    let mem = parse_member tks in
    mem :: parse_members tks term

let parse_type_def tks =
  let tk = Stream.next tks in
  let def, start = tk in
  match def with
  | TKeyword KStruct ->
      let name, _ = expect_ident tks in
      let _ = expect tks [TOpenBrace] "struct declaration" in
      let members = parse_members tks TCloseBrace in
      let last = expect tks [TCloseBrace] "struct declaration" in
      ( { epath= ([], name)
        ; emembers= members
        ; ekind= EStruct
        ; emods= ClassMods.empty }
      , {pfile= start.pfile; pmin= start.pmin; pmax= last.pmax} )
  | TKeyword KClass ->
      let name, _ = expect_ident tks in
      let ext =
        if next_is tks (TKeyword KExtends) then Some (parse_path tks) else None
      in
      let cl = {cextends= ext; cimplements= []} in
      let _ = expect tks [TOpenBrace] "class declaration" in
      let members = parse_members tks TCloseBrace in
      let last = expect tks [TCloseBrace] "class declaration" in
      ( { epath= ([], name)
        ; emembers= members
        ; ekind= EClass cl
        ; emods= ClassMods.empty }
      , {pfile= start.pfile; pmin= start.pmin; pmax= last.pmax} )
  | _ -> raise (Error (mk_one (Unexpected (def, "type definition")) start))
