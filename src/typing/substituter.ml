(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Type
open Reason
(*****************)
(* substitutions *)
(*****************)

(** Substitute bound type variables with associated types in a type. Do not
    force substitution under polymorphic types. This ensures that existential
    type variables under a polymorphic type remain unevaluated until the
    polymorphic type is applied. **)
let subst =
  let substituter = object(self)
    inherit [Type.t SMap.t * bool * use_op option] Type_mapper.t as super
    method! type_ cx map_cx t =
      let (map, force, use_op) = map_cx in
      if SMap.is_empty map then t
      else match t with
      | BoundT (tp_reason, name, _) ->
        begin match SMap.get name map with
        | None -> t
        | Some param_t when name = "this" ->
          ReposT (annot_reason tp_reason, param_t)
        | Some param_t ->
          (match desc_of_reason ~unwrap:false (reason_of_t param_t) with
          | RPolyTest _ ->
            mod_reason_of_t (fun reason ->
              annot_reason (repos_reason (loc_of_reason tp_reason) reason)
            ) param_t
          | _ ->
            param_t
          )
        end

      | ExistsT reason ->
        if force then Tvar.mk cx reason
        else t

      | DefT (reason, PolyT (xs, inner, _)) ->
        let xs, map, changed = List.fold_left (fun (xs, map, changed) typeparam ->
          let bound = self#type_ cx (map, force, use_op) typeparam.bound in
          let default = match typeparam.default with
          | None -> None
          | Some default ->
            let default_ = self#type_ cx (map, force, use_op) default in
            if default_ == default then typeparam.default else Some default_
          in
          { typeparam with bound; default; }::xs,
          SMap.remove typeparam.name map,
          changed || bound != typeparam.bound || default != typeparam.default
        ) ([], map, false) xs in
        let inner_ = self#type_ cx (map, false, None) inner in
        let changed = changed || inner_ != inner in
        if changed then DefT (reason, PolyT (List.rev xs, inner_, mk_id ())) else t

      | ThisClassT (reason, this) ->
        let map = SMap.remove "this" map in
        let this_ = self#type_ cx (map, force, use_op) this in
        if this_ == this then t else ThisClassT (reason, this_)

      | DefT (r, TypeAppT (op, c, ts)) ->
        let c' = self#type_ cx map_cx c in
        let ts' = ListUtils.ident_map (self#type_ cx map_cx) ts in
        if c == c' && ts == ts' then t else (
          (* If the TypeAppT changed then one of the type arguments had a
           * BoundT that was substituted. In this case, also change the use_op
           * so we can point at the op which instantiated the types that
           * were substituted. *)
          let use_op = Option.value use_op ~default:op in
          DefT (r, TypeAppT (use_op, c', ts'))
        )

      | EvalT (x, TypeDestructorT (op, r, d), _) ->
        let x' = self#type_ cx map_cx x in
        let d' = self#destructor cx map_cx d in
        if x == x' && d == d' then t
        else (
          (* If the EvalT changed then either the target or destructor had a
           * BoundT that was substituted. In this case, also change the use_op
           * so we can point at the op which instantiated the types that
           * were substituted. *)
          let use_op = Option.value use_op ~default:op in
          EvalT (x', TypeDestructorT (use_op, r, d'), Reason.mk_id ())
        )

      | ModuleT _
      | InternalT (ExtendsT _)
        ->
          failwith (Utils_js.spf "Unhandled type ctor: %s" (string_of_ctor t)) (* TODO *)

      | t -> super#type_ cx map_cx t

    method! predicate cx (map, force, use_op) p = match p with
    | LatentP (t, i) ->
      let t' = self#type_ cx (map, force, use_op) t in
      if t == t' then p else LatentP (t', i)
    | p -> p

    end in
  fun cx ?use_op ?(force=true) (map: Type.t SMap.t) ->
    substituter#type_ cx (map, force, use_op)
