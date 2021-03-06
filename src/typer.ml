(** This module is responsible for ensuring type safety in a program as it transforms expressions, values and types into their typed counterparts *)

open Ast
open Type
open Core_kernel

type ty_expr_def =
  | TECast of ty_expr * ty
  | TEThis
  | TESuper
  | TEConst of const
  | TEIdent of string
  | TEField of ty_expr * string
  | TEArrayIndex of ty_expr * ty_expr
  | TEBinOp of binop * ty_expr * ty_expr
  | TEUnOp of unop * ty_expr
  | TEBlock of ty_expr list
  | TECall of ty_expr * ty_expr list
  | TEParen of ty_expr
  | TEIf of ty_expr * ty_expr * ty_expr option
  | TEWhile of ty_expr * ty_expr
  | TEVar of variability * ty option * string * ty_expr
  | TENew of path * ty_expr list
  | TETuple of ty_expr list
  | TEBreak
  | TEContinue
  | TEReturn of ty_expr option

and ty_expr_meta = {edef: ty_expr_def; ety: ty}

(** Typed expression *)
and ty_expr = ty_expr_meta span

type ty_member_kind =
  | TMVar of variability * ty * ty_expr option
  | TMFunc of param list * ty * ty_expr
  | TMConstr of param list * ty_expr

type ty_member_def =
  { tmname: string
  ; tmkind: ty_member_kind
  ; tmmods: member_mods
  ; tmty: ty
  ; tmatts: (string, const) Hashtbl.t }

(** Typed type member *)
type ty_member = ty_member_def span

type ty_type_def_meta =
  { tepath: path
  ; tekind: type_def_kind
  ; temods: class_mods
  ; temembers: ty_member list }

type ty_type_def = ty_type_def_meta span

type ty_module_def =
  {tmimports: path list; tmdefs: ty_type_def list; tmpackage: pack}

type error_kind =
  | UnresolvedIdent of string
  | UnresolvedPath of path
  | CannotBinOp of binop * ty * ty
  | UnresolvedField of ty * string
  | CannotField of ty
  | UnresolvedFieldType of string
  | CannotAssign
  | CannotIndex
  | UnresolvedThis
  | UnresolvedSuper
  | Expected of ty * ty
  | CannotCall of ty
  | InvalidLHS
  | NoMatchingConstr of path * ty list
  | FunctionArgsMismatch of expr * ty list * ty list
  | NoReturn
  | CannotCastTo of ty
  | VoidVar

let error_msg = function
  | UnresolvedIdent s -> sprintf "Failed to resolve identifier '%s'" s
  | UnresolvedPath p -> sprintf "Unresolved path '%s'" (s_path p)
  | UnresolvedThis -> "Unresolved this"
  | UnresolvedSuper -> "Unresolved super"
  | CannotIndex -> "Cannot be indexed"
  | CannotBinOp (op, a, b) ->
      sprintf "Operation '%s' cannot be performed on types %s an %s"
        (s_binop op) (s_ty a) (s_ty b)
  | UnresolvedField (t, field) ->
      sprintf "Type %s has no field '%s'" (s_ty t) field
  | CannotField t ->
      sprintf "Type %s is not a struct or class, so has no fields" (s_ty t)
  | UnresolvedFieldType name ->
      sprintf "Type of field '%s' could not be resolved" name
  | Expected (t, got) ->
      sprintf "Expected type %s, got type %s" (s_ty t) (s_ty got)
  | CannotCall t -> sprintf "The type %s cannot be called" (s_ty t)
  | InvalidLHS -> "Invalid left-hand side of assignment"
  | CannotAssign ->
      "Cannot assign to this value. Did you mean to put 'var' instead of 'val'?"
  | NoMatchingConstr (p, ts) ->
      sprintf "No matching constructor found on '%s' taking args: %s"
        (s_path p)
        (String.concat ~sep:", " (List.map ~f:s_ty ts))
  | FunctionArgsMismatch (func, takes, got) ->
      sprintf "Function '%s' expects arguments %s but got %s" (s_expr "" func)
        (String.concat ~sep:", " (List.map ~f:s_ty takes))
        (String.concat ~sep:", " (List.map ~f:s_ty got))
  | NoReturn -> "No return"
  | CannotCastTo t -> "Cannot cast to " ^ s_ty t
  | VoidVar -> "Variables and constants cannot be void"

exception Error of error_kind span

(** The context needed to resolve types in a program *)
type type_context =
  { 
    (** Stack variables' variablity and types *)
    tvars: (string, variability * ty) Hashtbl.t Stack.t
    (** Map from type path to type definition used for type resolution *)
  ; ttypedefs: (path, Ast.type_def) Hashtbl.t
    (** Local this path if in instance member *)
  ; mutable tthis: path option
    (** True when the type member being parsed is static *)
  ; mutable tin_static: bool
    (** True when the type member being parsed is a constructor *)
  ; mutable tin_constructor: bool
    (** True when this type has explicitly returned *)
  ; mutable thas_return: bool }

(** Initialize this typer context with an empty stack, no type definitions, etc.*)
let init () =
  { tvars= Stack.create ()
  ; ttypedefs= Hashtbl.Poly.create ()
  ; tthis= None
  ; tin_static= true
  ; tin_constructor= false
  ; thas_return= false }

(** If [o] has a value return the value if not raise error [err] *)
let unwrap_or_err o err = match o with Some v -> v | None -> raise err

(** If [tbl] has key [key] then raise [err] *)
let find_or_err tbl key err = unwrap_or_err (Hashtbl.find tbl key) err

(** Enter a block *)
let enter_block ctx = Stack.push ctx.tvars (String.Table.create ~size:4 ())

(** Leave a block *)
let leave_block ctx = Stack.pop ctx.tvars

let rec try_resolve_field ctx ty name pos =
  let path =
    match ty with
    | TClass p -> p
    | TPath p -> p
    | _ -> raise (Error (CannotField ty, pos))
  in
  let tydef, _ =
    find_or_err ctx.ttypedefs path (Error (UnresolvedPath path, pos))
  in
  match List.find ~f:(fun (mem, _) -> mem.mname = name) tydef.emembers with
  | Some mem -> Some mem
  | None -> (
    match tydef.ekind with
    | EClass {cextends= Some ext; _} ->
        try_resolve_field ctx (TPath ext) name pos
    | _ -> None )

let resolve_field ctx ty name pos =
  unwrap_or_err
    (try_resolve_field ctx ty name pos)
    (Error (UnresolvedField (ty, name), pos))

let ty_of tex =
  let meta, _ = tex in
  meta.ety

let set_var ctx name var ty =
  printf "var '%s': %s" name (s_ty ty) ;
  ignore (Hashtbl.add (Stack.top_exn ctx.tvars) ~key:name ~data:(var, ty))

let rec as_pack ctx ex =
  let edef, _ = ex in
  match edef with
  | EIdent id -> [id]
  | EField (o, f) -> as_pack ctx o @ [f]
  | _ -> []

let as_path ctx ex =
  let pack = as_pack ctx ex in
  if pack = [] then None
  else
    let pack_arr = Array.of_list pack in
    let name = pack_arr.(Array.length pack_arr - 1) in
    let pack_arr =
      Array.sub pack_arr ~pos:0 ~len:(Array.length pack_arr - 1)
    in
    Some (Array.to_list pack_arr, name)

let find_matching_constr ctx path args pos =
  let def, _ = find_or_err ctx.ttypedefs path (Failure "type not found") in
  let constr =
    List.find
      ~f:(fun (def, _) ->
        match def.mkind with
        | MConstr (params, _) -> List.map ~f:(fun p -> p.ptype) params = args
        | _ -> false )
      def.emembers
  in
  unwrap_or_err constr (Error (NoMatchingConstr (path, args), pos))

(** Checks whether the type `source` can be casted to `target` *)
let rec can_cast ctx source target =
  match (source, target) with
  | a, b when is_numeric a && is_numeric b -> true
  | TPath a, TPath b -> (
      let a_def, _ = Hashtbl.find_exn ctx.ttypedefs a in
      match a_def.ekind with
      | EClass {cextends= Some super; cimplements} ->
          List.mem cimplements b ~equal:(fun a b -> a = b)
          || super = b
          || can_cast ctx source (TPath super)
      | _ -> false )
  | _ -> false

(** Type the expression `ex` and return its typed equivalent *)
let rec type_expr ctx ex =
  let edef, pos = ex in
  let mk def ty =
    ({edef= def; ety= ty}, {pfile= pos.pfile; pmin= pos.pmin; pmax= pos.pmax})
  in
  let type_expr_lhs ctx (edef, pos) =
    match edef with
    | EIdent id -> (
      match find_var ctx id pos with
      | Some (Variable, v) -> mk (TEIdent id) v
      | Some (Constant, _) -> raise (Error (CannotAssign, pos))
      | _ -> raise (Error (UnresolvedIdent id, pos)) )
    | EField (o, f) ->
        let obj = type_expr ctx o in
        let member = resolve_field ctx (ty_of obj) f pos in
        let var, mem = type_of_member ctx member in
        if var = Variable then mk (TEField (obj, f)) mem
        else raise (Error (CannotAssign, pos))
    | _ -> raise (Error (InvalidLHS, pos))
  in
  match edef with
  | EConst c -> mk (TEConst c) (TPrim (type_of_const c))
  | ECast (v, t) ->
      let v = type_expr ctx v in
      ( match (ty_of v, t) with
      | a, b when can_cast ctx a b -> ()
      | _ -> raise (Error (CannotCastTo t, pos)) ) ;
      mk (TECast (v, t)) t
  | EThis ->
      let path = unwrap_or_err ctx.tthis (Error (UnresolvedThis, pos)) in
      mk TEThis (TPath path)
  | ESuper ->
      let path = unwrap_or_err ctx.tthis (Error (UnresolvedThis, pos)) in
      let this_def, _ =
        find_or_err ctx.ttypedefs path (Error (UnresolvedThis, pos))
      in
      let extends =
        match this_def.ekind with
        | EClass def ->
            unwrap_or_err def.cextends (Error (UnresolvedSuper, pos))
        | _ -> raise (Error (UnresolvedSuper, pos))
      in
      mk TESuper (TPath extends)
  | EIdent id -> (
      let v = find_var ctx id pos in
      match v with
      | Some (_, v) -> mk (TEIdent id) v
      | None when Hashtbl.mem ctx.ttypedefs ([], id) ->
          let path =
            match as_path ctx ex with
            | Some v -> v
            | None -> raise (Failure "")
          in
          mk (TEIdent id) (TClass path)
      | None -> raise (Error (UnresolvedIdent id, pos)) )
  | EVar (vari, t, name, v) ->
      let v = type_expr ctx v in
      set_var ctx name vari (ty_of v) ;
      ( match t with
      | Some t when ty_of v <> t -> raise (Error (Expected (t, ty_of v), pos))
      | _ -> () ) ;
      if ty_of v <> TPrim TVoid then
        mk (TEVar (vari, t, name, v)) (TPrim TVoid)
      else raise (Error (VoidVar, pos))
  | EParen inner ->
      let inner = type_expr ctx inner in
      mk (TEParen inner) (ty_of inner)
  | EField (o, f) ->
      let obj = type_expr ctx o in
      let member = resolve_field ctx (ty_of obj) f pos in
      let _, mem = type_of_member ctx member in
      mk (TEField (obj, f)) mem
  | EArrayIndex (o, i) ->
      let obj = type_expr ctx o in
      let ind = type_expr ctx i in
      let var_t =
        match ty_of obj with
        | TTuple vs ->
            let ind =
              match i with
              | EConst (CInt v), _ -> v
              | _ -> raise (Failure "failed to parse index")
            in
            (Array.of_list vs).(ind)
        | _ -> raise (Error (CannotIndex, pos))
      in
      mk (TEArrayIndex (obj, ind)) var_t
  | EUnOp (op, v) ->
      let v = type_expr ctx v in
      mk (TEUnOp (op, v)) (ty_of v)
  | EBinOp (op, a_e, b_e) -> (
      let a = type_expr ctx a_e in
      let b = type_expr ctx b_e in
      let a_ty = ty_of a in
      let b_ty = ty_of b in
      let res_ty =
        match op with
        | OpAdd | OpSub | OpDiv | OpMul ->
            if is_numeric a_ty && is_numeric b_ty && a_ty = b_ty then Some a_ty
            else None
        | OpEq | OpLt -> if a_ty = b_ty then Some (TPrim TBool) else None
        | _ when is_assign op ->
            let lhs = type_expr_lhs ctx a_e in
            assert (ty_of lhs = a_ty) ;
            if a_ty = b_ty then Some a_ty else None
        | _ -> assert false
      in
      match res_ty with
      | None -> raise (Error (CannotBinOp (op, a_ty, b_ty), pos))
      | Some ty -> mk (TEBinOp (op, a, b)) ty )
  | EBlock exs ->
      let ty = ref (TPrim TVoid) in
      let exs =
        List.map
          ~f:(fun ex ->
            let ty_ex = type_expr ctx ex in
            let meta, _ = ty_ex in
            ty := meta.ety ;
            ty_ex )
          exs
      in
      mk (TEBlock exs) !ty
  | ECall (((ESuper, _) as super), args) ->
      let this = unwrap_or_err ctx.tthis (Error (UnresolvedThis, pos)) in
      let this_def, _ =
        find_or_err ctx.ttypedefs this (Error (UnresolvedThis, pos))
      in
      let extends =
        match this_def.ekind with
        | EClass def ->
            unwrap_or_err def.cextends (Error (UnresolvedSuper, pos))
        | _ -> raise (Error (UnresolvedSuper, pos))
      in
      let super = type_expr ctx super in
      let args = List.map ~f:(type_expr ctx) args in
      let arg_tys = List.map ~f:ty_of args in
      let _ = find_matching_constr ctx extends arg_tys pos in
      mk (TECall (super, args)) (TPrim TVoid)
  | ECall (func_d, args) ->
      let func = type_expr ctx func_d in
      let args = List.map ~f:(type_expr ctx) args in
      mk
        (TECall (func, args))
        ( match ty_of func with
        | TFunc (params, ret, FNormal) ->
            let pargs = List.map args ~f:ty_of in
            if params <> pargs then
              raise (Error (FunctionArgsMismatch (func_d, params, pargs), pos))
            else ret
        | TFunc (params, ret, FVarArgs) ->
            let pargs = List.map args ~f:ty_of in
            if params <> List.sub pargs ~pos:0 ~len:(List.length params) then
              raise (Error (FunctionArgsMismatch (func_d, params, pargs), pos))
            else ret
        | t -> raise (Error (CannotCall t, pos)) )
  | EIf (cond, if_e, None) ->
      let cond = type_expr ctx cond in
      let if_e = type_expr ctx if_e in
      let _, pos = cond in
      if ty_of cond <> TPrim TBool then
        raise (Error (Expected (TPrim TBool, ty_of cond), pos)) ;
      mk (TEIf (cond, if_e, None)) (ty_of if_e)
  | EIf (cond, if_e, Some else_e) ->
      let cond = type_expr ctx cond in
      let if_e = type_expr ctx if_e in
      let else_e = type_expr ctx else_e in
      let _, pos = cond in
      if ty_of cond <> TPrim TBool then
        raise (Error (Expected (TPrim TBool, ty_of cond), pos)) ;
      mk (TEIf (cond, if_e, Some else_e)) (ty_of if_e)
  | EWhile (cond, body) ->
      let cond = type_expr ctx cond in
      let body = type_expr ctx body in
      if ty_of cond <> TPrim TBool then
        raise (Error (Expected (TPrim TBool, ty_of cond), pos)) ;
      mk (TEWhile (cond, body)) (TPrim TVoid)
  | ENew (path, args) ->
      let _ =
        find_or_err ctx.ttypedefs path (Error (UnresolvedPath path, pos))
      in
      let args = List.map ~f:(type_expr ctx) args in
      let arg_tys = List.map ~f:ty_of args in
      let _ = find_matching_constr ctx path arg_tys pos in
      mk (TENew (path, args)) (TPath path)
  | ETuple mems ->
      let mems = List.map ~f:(type_expr ctx) mems in
      let ty = TTuple (List.map ~f:ty_of mems) in
      mk (TETuple mems) ty
  | EBreak | EContinue -> mk TEBreak (TPrim TVoid)
  | EReturn v ->
      ctx.thas_return <- true ;
      let v = match v with Some v -> Some (type_expr ctx v) | None -> None in
      mk (TEReturn v) (TPrim TVoid)

and type_of_member ctx (def, pos) =
  ctx.tin_static <- Set.mem def.mmods MStatic;
  match def.mkind with
  | MVar (v, Some ty, _) -> (v, ty)
  | MVar (v, None, Some c) -> (v, ty_of (type_expr ctx c))
  | MVar _ -> raise (Error (UnresolvedFieldType def.mname, pos))
  | MFunc (params, ret, _) ->
      ( Constant
      , TFunc
          ( List.map ~f:(fun par -> par.ptype) params
          , ret
          , if Hashtbl.find def.matts "CallConv" = Some (CString "vararg") then
              FVarArgs
            else FNormal ) )
  | MConstr (params, _) ->
      ( Constant
      , TFunc (List.map ~f:(fun par -> par.ptype) params, TPrim TVoid, FNormal)
      )

and find_var ctx name pos =
  let res : (variability * ty) option ref = ref None in
  print_endline "dumping stack" ;
  Stack.iter
    ~f:(fun tbl ->
      Hashtbl.iteri tbl ~f:(fun ~key:name ~data:(_, v) ->
          print_endline (name ^ ":" ^ s_ty v) ) ;
      if !res <> None then ()
      else
        match Hashtbl.find tbl name with Some v -> res := Some v | None -> ()
      )
    ctx.tvars ;
  ( match ctx.tthis with
  | Some t when !res = None -> (
      let mem = try_resolve_field ctx (TPath t) name pos in
      match mem with
      | Some mem -> res := Some (type_of_member ctx mem)
      | _ -> () )
  | _ -> () ) ;
  !res

and type_of_const = function
  | CInt _ -> TInt
  | CFloat _ -> TFloat
  | CString _ -> TString
  | CBool _ -> TBool
  | CNull -> TVoid

(** Type a type member into its typed counterpart *)
let type_member ctx (def, pos) =
  ctx.tin_static <- Set.mem def.mmods MStatic ;
  ctx.tin_constructor <- false ;
  ctx.thas_return <- false ;
  let kind =
    match def.mkind with
    | MVar (v, Some ty, None) -> TMVar (v, ty, None)
    | MVar (v, _, Some c) ->
      let e = type_expr ctx c in
      TMVar (v, ty_of e, Some e)
    | MVar (_, None, None) ->
        raise (Error (UnresolvedFieldType def.mname, pos))
    | MFunc (params, ret, body) ->
        let _ = enter_block ctx in
        List.iter
          ~f:(fun par -> set_var ctx par.pname Constant par.ptype)
          params ;
        let body = type_expr ctx body in
        if ty_of body <> ret && not ctx.thas_return then
          raise (Error (NoReturn, pos)) ;
        let _ = leave_block ctx in
        TMFunc (params, ret, body)
    | MConstr (params, body) ->
        let _ = enter_block ctx in
        ctx.tin_constructor <- true ;
        List.iter
          ~f:(fun par -> set_var ctx par.pname Constant par.ptype)
          params ;
        let body = type_expr ctx body in
        let _ = leave_block ctx in
        ctx.tin_constructor <- false ;
        TMConstr (params, body)
  in
  let _, tmty = type_of_member ctx (def, pos) in
  ( { tmkind= kind
    ; tmname= def.mname
    ; tmmods= def.mmods
    ; tmatts= def.matts
    ; tmty }
  , pos )

let type_type_def ctx (def, pos) =
  ctx.tthis <- Some def.epath ;
  ignore (Hashtbl.add ctx.ttypedefs ~key:def.epath ~data:(def, pos)) ;
  ( { tepath= def.epath
    ; tekind= def.ekind
    ; temods= def.emods
    ; temembers= List.map ~f:(type_member ctx) def.emembers }
  , pos )

(** Type this module into its typed counterpart*)
let type_mod ctx m =
  List.iter
    ~f:(fun (def, pos) ->
      ignore (Hashtbl.add ctx.ttypedefs ~key:def.epath ~data:(def, pos)) )
    m.mdefs ;
  let defs : ty_type_def list = List.map ~f:(type_type_def ctx) m.mdefs in
  {tmimports= m.mimports; tmdefs= defs; tmpackage= m.mpackage}

let rec s_ty_expr tabs (meta, _) =
  match meta.edef with
  | TECast (v, t) -> sprintf "%s as %s" (s_ty_expr tabs v) (s_ty t)
  | TESuper -> "super"
  | TEThis -> "this"
  | TEConst c -> s_const c
  | TEIdent id -> id
  | TEField (o, f) -> sprintf "%s.%s" (s_ty_expr tabs o) f
  | TEArrayIndex (a, i) ->
      sprintf "%s[%s]" (s_ty_expr tabs a) (s_ty_expr tabs i)
  | TEBinOp (op, a, b) ->
      sprintf "%s %s %s" (s_ty_expr tabs a) (s_binop op) (s_ty_expr tabs b)
  | TEUnOp (op, a) -> sprintf "%s%s" (s_unop op) (s_ty_expr tabs a)
  | TEBlock exs ->
      sprintf "{%s\n%s}"
        (String.concat ~sep:""
           (List.map
              ~f:(fun ex -> tabs ^ "\t" ^ s_ty_expr (tabs ^ "\t") ex ^ "\n")
              exs))
        tabs
  | TECall (f, exs) ->
      sprintf "%s(%s)" (s_ty_expr tabs f)
        (String.concat ~sep:"," (List.map ~f:(s_ty_expr tabs) exs))
  | TEParen ex -> sprintf "(%s)" (s_ty_expr tabs ex)
  | TEIf (cond, if_e, None) ->
      sprintf "if %s %s" (s_ty_expr tabs cond) (s_ty_expr tabs if_e)
  | TEIf (cond, if_e, Some else_e) ->
      sprintf "if %s %s else %s" (s_ty_expr tabs cond) (s_ty_expr tabs if_e)
        (s_ty_expr tabs else_e)
  | TEWhile (cond, body) ->
      sprintf "while %s %s" (s_ty_expr tabs cond) (s_ty_expr tabs body)
  | TEVar (v, None, name, ex) ->
      sprintf "%s %s = %s" (s_variability v) name (s_ty_expr tabs ex)
  | TEVar (v, Some t, name, ex) ->
      sprintf "%s %s: %s = %s" (s_variability v) name (s_ty t)
        (s_ty_expr tabs ex)
  | TENew (path, args) ->
      sprintf "new %s(%s)" (s_path path)
        (String.concat ~sep:"," (List.map ~f:(s_ty_expr tabs) args))
  | TETuple mems ->
      sprintf "(%s)"
        (String.concat ~sep:", " (List.map ~f:(s_ty_expr tabs) mems))
  | TEBreak -> "break"
  | TEContinue -> "continue"
  | TEReturn None -> "return"
  | TEReturn (Some v) -> sprintf "return %s" (s_ty_expr tabs v)

let s_ty_member ((mem, _) : ty_member) : string =
  match mem.tmkind with
  | TMVar (vr, ty, va) ->
      sprintf "%s %s: %s %s" (s_var vr) mem.tmname (s_ty ty)
        (match va with Some v -> " = " ^ s_ty_expr "" v | _ -> "")
  | TMFunc (pars, ret, body) ->
      sprintf "func %s(%s): %s %s" mem.tmname
        (String.concat ~sep:"," (List.map ~f:s_param pars))
        (s_ty ret) (s_ty_expr "\t" body)
  | TMConstr (pars, body) ->
      sprintf "func new(%s) %s"
        (String.concat ~sep:"," (List.map ~f:s_param pars))
        (s_ty_expr "\t" body)

let s_ty_type_def ((def, _) : ty_type_def) : string =
  sprintf "%s %s {\n%s\n}"
    (match def.tekind with EClass _ -> "class" | EStruct -> "struct")
    (s_path def.tepath)
    (String.concat ~sep:"\n\t" (List.map ~f:s_ty_member def.temembers))

let s_ty_module m =
  sprintf "package %s\n%s" (s_pack m.tmpackage)
    (String.concat ~sep:"\n" (List.map ~f:s_ty_type_def m.tmdefs))
