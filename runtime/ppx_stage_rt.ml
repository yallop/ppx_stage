open Migrate_parsetree
open Ast_405

open Asttypes
open Parsetree
open Ast_helper

type ident = string
module IdentMap = Map.Make (struct type t = ident let compare = compare end)

type _ tag = ..
module type T = sig 
  type a
  type _ tag += Tag : a tag
  val name : string
end
type 'a variable = (module T with type a = 'a)

let fresh_variable (type aa) name : aa variable =
  (module struct 
     type a = aa
     type _ tag += Tag : a tag
     let name = name
   end)

module VarMap (C : sig type 'a t end) : sig
  type t
  val empty : t
  val add : t -> 'a variable -> 'a C.t -> t
  val lookup : t -> 'a variable -> 'a C.t option
end = struct
  type entry = Entry : 'b variable * 'b C.t -> entry
  type t = entry list
  let empty = []
  let add m v x = (Entry (v, x) :: m)
  let rec lookup : type a . t -> a variable -> a C.t option =
    fun m v ->
    match m with
    | [] -> None
    | (Entry ((module V'), x')) :: m ->
       let (module V) = v in
       match V.Tag with
       | V'.Tag -> Some x'
       | _ -> lookup m v
end

module Environ = VarMap (struct type 'a t = 'a end)
module Renaming = VarMap (struct type 'a t = int end)

type 'a t = Ppx_stage_internal of (Environ.t -> 'a) * (Renaming.t -> expression)

let variable_name (type a) (v : a variable) =
  let module V = (val v) in
  V.name

let mangle id n =
  id ^ "''" ^ string_of_int n


let of_variable v =
  Ppx_stage_internal
    ((fun env ->
      match Environ.lookup env v with
      | Some x -> x
      | None ->
         failwith ("Variable " ^ variable_name v ^ " used out of scope")),
     (fun ren ->
      match Renaming.lookup ren v with
      | Some n -> Exp.ident (Location.mknoloc (Longident.Lident (mangle (variable_name v ) n)))
      | None ->
         failwith ("Variable " ^ variable_name v ^ " used out of scope")))

let compute (Ppx_stage_internal (c, s)) = c
let source (Ppx_stage_internal (c, s)) = s

let run f = compute f Environ.empty

let print ppf f =
  Pprintast.expression ppf (Versions.((migrate ocaml_405 ocaml_current).copy_expression (source f Renaming.empty)))








type binding_site = int
type scope = binding_site IdentMap.t

type hole = int

type analysis_env = {
  bindings : scope;
  fresh : unit -> binding_site;
  hole_table : (hole, scope) Hashtbl.t
}

let is_hole = function
  | { txt = Longident.Lident v; _ } -> v.[0] == ','
  | _ -> false

let hole_id v : hole =
  assert (is_hole v);
  match v with
  | { txt = Longident.Lident v; _ } ->
     int_of_string (String.sub v 1 (String.length v - 1))
  | _ -> assert false

let rec analyse_exp env { pexp_desc; pexp_loc; pexp_attributes } =
  analyse_attributes pexp_attributes;
  analyse_exp_desc env pexp_loc pexp_desc

and analyse_exp_desc env loc = function
  | Pexp_ident id when is_hole id ->
     (* found a hole *)
     Hashtbl.add env.hole_table (hole_id id) env.bindings
  | Pexp_ident _ -> ()
  | Pexp_constant k -> ()
  | Pexp_let (isrec, vbs, body) ->
     let env' = List.fold_left (fun env {pvb_pat; _} ->
       analyse_pat env pvb_pat) env vbs in
     let bindings_env =
       match isrec with Recursive -> env' | Nonrecursive -> env in
     vbs |> List.iter (fun vb ->
       analyse_exp bindings_env vb.pvb_expr;
       analyse_attributes vb.pvb_attributes);
     analyse_exp env' body
  | Pexp_function cases ->
     List.iter (analyse_case env) cases
  | Pexp_fun (lbl, opt, pat, body) ->
     analyse_exp_opt env opt;
     let env' = analyse_pat env pat in
     analyse_exp env' body
  | Pexp_apply (fn, args) ->
     analyse_exp env fn;
     args |> List.iter (fun (_, e) -> analyse_exp env e)
  | Pexp_match (exp, cases) ->
     analyse_exp env exp;
     List.iter (analyse_case env) cases
  | Pexp_try (exp, cases) ->
     analyse_exp env exp;
     List.iter (analyse_case env) cases
  | Pexp_tuple exps ->
     List.iter (analyse_exp env) exps
  | Pexp_construct (_ctor, exp) ->
     analyse_exp_opt env exp
  (* several missing... *)
  | Pexp_sequence (e1, e2) ->
     analyse_exp env e1; analyse_exp env e2
  | _ -> raise (Location.(Error (error ~loc ("expression not supported in staged code"))))

and analyse_exp_opt env = function
  | None -> ()
  | Some e -> analyse_exp env e

and analyse_pat env { ppat_desc; ppat_loc; ppat_attributes } =
  analyse_attributes ppat_attributes;
  analyse_pat_desc env ppat_loc ppat_desc

and analyse_pat_desc env loc = function
  | Ppat_any -> env
  | Ppat_var v -> analyse_pat_desc env loc (Ppat_alias (Pat.any (), v))
  | Ppat_alias (pat, v) ->
     let env = analyse_pat env pat in
     { env with bindings = IdentMap.add v.txt (env.fresh ()) env.bindings }
  | Ppat_constant _ -> env
  | Ppat_interval _ -> env
  | Ppat_tuple pats -> List.fold_left analyse_pat env pats
  | Ppat_construct (loc, None) -> env
  | Ppat_construct (loc, Some pat) -> analyse_pat env pat
  | _ -> raise (Location.(Error (error ~loc ("pattern not supported in staged code"))))

and analyse_case env {pc_lhs; pc_guard; pc_rhs} =
  let env' = analyse_pat env pc_lhs in
  analyse_exp_opt env' pc_guard;
  analyse_exp env' pc_rhs

and analyse_attributes = function
| [] -> ()
| ({ loc; txt }, PStr []) :: rest ->
   analyse_attributes rest
| ({ loc; txt }, _) :: _ ->
   raise (Location.(Error (error ~loc ("attribute " ^ txt ^ " not supported in staged code"))))


let analyse_binders (e : expression) : (hole, scope) Hashtbl.t =
  let hole_table = Hashtbl.create 20 in
  let next_binder = ref 0 in
  let fresh () =
    incr next_binder;
    !next_binder in
  analyse_exp { bindings = IdentMap.empty; fresh; hole_table } e;
  hole_table


open Ast_mapper
let substitute_holes (e : expression) (f : int -> expression) =
  let expr mapper pexp =
    match pexp.pexp_desc with
    | Pexp_ident v when is_hole v ->
       f (hole_id v)
    | _ -> default_mapper.expr mapper pexp in
  let mapper = { default_mapper with expr } in
  mapper.expr mapper e
       

let with_renaming
    (v : 'a variable) (binding : ident)
    (f : Renaming.t -> expression)
    (ren : Renaming.t) : expression =
  let idx =
    match Renaming.lookup ren v with
    | None -> 0
    | Some n -> n + 1 in
  [%expr
      let
        [%p Pat.var (Location.mknoloc (mangle (variable_name v) idx))]
          =
        [%e Exp.ident (Location.mknoloc (Longident.Lident binding))]
      in
      [%e f
          (Renaming.add ren v idx)]]
