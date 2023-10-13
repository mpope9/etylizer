-module(dnf_ty_function).

-ifdef(TEST).
-export([explore_function_norm/6]).
-endif.

-define(P, {bdd_bool, ty_function}).
-define(F(Z), fun() -> Z end).


-export([equal/2, compare/2]).

%%
-export([empty/0, any/0, union/2, intersect/2, diff/2, negate/1]).
-export([is_any/1, normalize/6, substitute/4, is_empty/1]).

-export([function/1, all_variables/1, has_ref/2, transform/2]).

-type ty_ref() :: {ty_ref, integer()}.
-type dnf_function() :: term().
-type ty_function() :: dnf_function(). % ty_function:type()
-type dnf_ty_function() :: term().

-spec function(ty_function()) -> dnf_ty_function().
function(TyFunction) -> gen_bdd:element(?P, TyFunction).

empty() -> gen_bdd:empty(?P).
any() -> gen_bdd:any(?P).
transform(Ty, Ops) -> gen_bdd:transform(?P, Ty, Ops).
substitute(MkTy, TyBDD, Map, Memo) -> gen_bdd:substitute(?P, MkTy, TyBDD, Map, Memo).
union(B1, B2) -> gen_bdd:union(?P, B1, B2).
intersect(B1, B2) -> gen_bdd:intersect(?P, B1, B2).
diff(B1, B2) -> gen_bdd:diff(?P, B1, B2).
negate(B1) -> gen_bdd:negate(?P, B1).
is_any(B) -> gen_bdd:is_any(?P, B).
has_ref(Ty, Ref) -> gen_bdd:has_ref(?P, Ty, Ref).
all_variables(TyBDD) -> gen_bdd:all_variables(?P, TyBDD).
equal(B1, B2) -> gen_bdd:equal(?P, B1, B2).
compare(B1, B2) -> gen_bdd:compare(?P, B1, B2).

is_empty(TyBDD) ->
  gen_bdd:dnf(?P, TyBDD, {fun is_empty_coclause/3, fun gen_bdd:is_empty_union/2}).

is_empty_coclause(AllPos, Neg, T) ->
  case bdd_bool:empty() of
    T -> true;
    _ -> case AllPos of
           [] -> false;
           [P | Pos] ->
             % TODO here do these simplifications
             % A -> B && C -> B == A|C -> B
             % A -> B && A -> C == A -> B&C
             BigSTuple = lists:foldl(fun(FunTy, Acc) ->
               ty_rec:union(Acc, domains_to_tuple(ty_function:domains(FunTy)))
                                     end, domains_to_tuple(ty_function:domains(P)), Pos),
             is_empty_cont(BigSTuple, AllPos, Neg)
         end
  end.

is_empty_cont(_, _, []) -> false;
is_empty_cont(BigSTuple, P, [Function | N]) ->
  Ts = ty_function:domains(Function),
  T2 = ty_function:codomain(Function),
  (
      %% ∃ Ts-->T2 ∈ N s.t.
      %%    Ts is in the domains of the function
      %%    BigS is the union of all domains of the positive function intersections
      ty_rec:is_subtype(domains_to_tuple(Ts), BigSTuple)
        andalso
        explore_function(domains_to_tuple(Ts), ty_rec:negate(T2), P)
  )
  %% Continue searching for another arrow ∈ N
    orelse
    is_empty_cont(BigSTuple, P, N).

domains_to_tuple(Domains) ->
  ty_rec:tuple(length(Domains), dnf_var_ty_tuple:tuple(dnf_ty_tuple:tuple(ty_tuple:tuple(Domains)))).

% optimized phi' (4.10) from paper covariance and contravariance
% justification for this version of phi can be found in `prop_phi_function.erl`
-spec explore_function(ty_ref(), ty_ref(), [term()]) -> boolean().
explore_function(Ts, T2, []) ->
  ty_rec:is_empty(T2) orelse ty_rec:is_empty(Ts);
explore_function(Ts, T2, [Function | P]) ->
  ty_rec:is_empty(Ts) orelse ty_rec:is_empty(T2)
  orelse
    begin
      BigS1 = domains_to_tuple(ty_function:domains(Function)),
      S2 = ty_function:codomain(Function),
      explore_function(Ts, ty_rec:intersect(T2, S2), P)
        andalso
        explore_function(ty_rec:diff(Ts, BigS1), T2, P)
    end.

normalize(_Size, DnfTyFunction, [], [], Fixed, M) ->
  gen_bdd:dnf(?P, DnfTyFunction, {
    fun(Pos, Neg, DnfTyList) -> normalize_coclause(Pos, Neg, DnfTyList, Fixed, M) end,
    fun constraint_set:meet/2
  })
;
normalize(Size, DnfTyFunction, PVar, NVar, Fixed, M) ->
  Ty = ty_rec:function(Size, dnf_var_ty_function:function(DnfTyFunction)),
  % ntlv rule
  ty_variable:normalize(Ty, PVar, NVar, Fixed, fun(Var) -> ty_rec:function(Size, dnf_var_ty_function:var(Var)) end, M).

normalize_coclause(Pos, Neg, T, Fixed, M) ->
  case bdd_bool:empty() of
    T -> [[]];
    _ ->
      [First | _] = Pos ++ Neg,
      AllDomainsAsTuples = [ty_tuple:tuple(ty_function:domains(Fun)) || Fun <- Pos],
      Size = length(ty_function:domains(First)),
      S = ty_rec:tuple(Size, dnf_var_ty_tuple:tuple(dnf_ty_tuple:tuple(ty_tuple:big_union(AllDomainsAsTuples)))),
      normalize_no_vars(Size, S, Pos, Neg, Fixed, M)
  end.

normalize_no_vars(_Size, _, _, [], _Fixed, _) -> []; % non-empty
normalize_no_vars(Size, S, P, [Function | N], Fixed, M) ->
  T1 = domains_to_tuple(ty_function:domains(Function)),
  T2 = ty_function:codomain(Function),
  %% ∃ T1-->T2 ∈ N s.t.
  %%   T1 is in the domain of the function
  %%   S is the union of all domains of the positive function intersections
  X1 = ?F(ty_rec:normalize(ty_rec:intersect(T1, ty_rec:negate(S)), Fixed, M)),
  X2 = ?F(explore_function_norm(Size, T1, ty_rec:negate(T2), P, Fixed, M)),
  R1 = ?F(constraint_set:meet(X1, X2)),
  %% Continue searching for another arrow ∈ N
  R2 = ?F(normalize_no_vars(Size, S, P, N, Fixed, M)),
  constraint_set:join(R1, R2).


explore_function_norm(_Size, BigT1, T2, [], Fixed, M) ->
  NT1 = ?F(ty_rec:normalize(BigT1, Fixed, M)),
  NT2 = ?F(ty_rec:normalize(T2, Fixed, M)),
  constraint_set:join( NT1, NT2 );
explore_function_norm(Size, T1, T2, [Function | P], Fixed, M) ->
  NT1 = ?F(ty_rec:normalize(T1, Fixed, M)),
  NT2 = ?F(ty_rec:normalize(T2, Fixed, M)),

  S1 = domains_to_tuple(ty_function:domains(Function)),
  S2 = ty_function:codomain(Function),

  NS1 = ?F(explore_function_norm(Size, T1, ty_rec:intersect(T2, S2), P, Fixed, M)),
  NS2 = ?F(explore_function_norm(Size, ty_rec:diff(T1, S1), T2, P, Fixed, M)),

  constraint_set:join(NT1,
    ?F(constraint_set:join(NT2,
      ?F(constraint_set:meet(NS1, NS2))))).
