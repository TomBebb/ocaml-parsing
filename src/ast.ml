open Type
open Printf

type const =
  | CInt of int
  | CFloat of float
  | CString of string
  | CBool of bool
  | CNull

type binop = OpAdd | OpSub | OpMul | OpDiv | OpAssign | OpEq

type unop = OpNeg | OpNot

type pos_detail = {pline: int; pcol: int}

type pos = {pfile: string; pmin: pos_detail; pmax: pos_detail}

type 'a span = 'a * pos

let span_v (v, _) = v

type variability =
  | Variable
  | Constant

type expr_def =
  | EThis
  | EConst of const
  | EIdent of string
  | EField of expr * string
  | EBinOp of binop * expr * expr
  | EUnOp of unop * expr
  | EBlock of expr list
  | ECall of expr * expr list
  | EParen of expr
  | EIf of expr * expr * expr option
  | EWhile of expr * expr
  | EVar of variability * ty option * string * expr
  | ENew of path * expr list

and expr = expr_def span

type param = {pname: string; ptype: ty}

type member_kind =
  | MVar of variability * ty option * expr option
  | MFunc of param list * ty * expr
  | MConstr of param list * expr

type member_mod = MStatic | MPublic | MPrivate | MExtern

module MemberMods = Set.Make (struct
  let compare = Pervasives.compare

  type t = member_mod
end)

type member_def =
  { mname: string
  ; mkind: member_kind
  ; mmods: MemberMods.t
  ; matts: (string, const) Hashtbl.t }

type member = member_def span

type class_mod = CPublic | CPrivate

module ClassMods = Set.Make (struct
  let compare = Pervasives.compare

  type t = class_mod
end)

type class_def = {cextends: path option; cimplements: path list}

type type_def_kind = EClass of class_def | EStruct

type type_def_meta =
  {epath: path; ekind: type_def_kind; emods: ClassMods.t; emembers: member list}

type type_def = type_def_meta span

let s_pos p = Printf.sprintf "%s: %d:%d" p.pfile p.pmin.pline p.pmin.pcol

let s_const = function
  | CInt i -> string_of_int i
  | CFloat f -> string_of_float f
  | CString s -> "\"" ^ s ^ "\""
  | CBool b -> string_of_bool b
  | CNull -> "null"

let s_binop = function
  | OpAdd -> "+"
  | OpSub -> "-"
  | OpMul -> "*"
  | OpDiv -> "/"
  | OpAssign -> "="
  | OpEq -> "=="

let s_unop = function OpNeg -> "-" | OpNot -> "!"


let s_variability = function
  | Variable -> "var"
  | Constant -> "val"

let rec s_expr tabs (def, _) =
  match def with
  | EThis -> "this"
  | EConst c -> s_const c
  | EIdent id -> id
  | EField (o, f) -> s_expr tabs o ^ "." ^ f
  | EBinOp (op, a, b) -> s_expr tabs a ^ s_binop op ^ s_expr tabs b
  | EUnOp (op, a) -> s_unop op ^ s_expr tabs a
  | EBlock exs ->
      "{"
      ^ String.concat ("\n" ^ tabs) (List.map (s_expr (tabs ^ "\t")) exs)
      ^ "}"
  | ECall (f, exs) ->
      s_expr tabs f ^ "("
      ^ String.concat "," (List.map (s_expr tabs) exs)
      ^ ")"
  | EParen ex -> "(" ^ s_expr tabs ex ^ ")"
  | EIf (cond, if_e, None) -> "if " ^ s_expr tabs cond ^ " " ^ s_expr tabs if_e
  | EIf (cond, if_e, Some else_e) ->
      "if " ^ s_expr tabs cond ^ " " ^ s_expr tabs if_e ^ " else "
      ^ s_expr tabs else_e
  | EWhile (cond, body) -> "while " ^ s_expr tabs cond ^ " " ^ s_expr tabs body
  | EVar (v, None, name, ex) -> sprintf "%s %s = %s" (s_variability v) name (s_expr tabs ex)
  | EVar (v, Some t, name, ex) ->
      sprintf "%s %s: %s = %s" (s_variability v) name (s_ty t) (s_expr tabs ex)
  | ENew (path, args) ->
      sprintf "new %s(%s)" (s_path path)
        (String.concat "," (List.map (s_expr tabs) args))
