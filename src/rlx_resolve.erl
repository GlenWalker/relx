-module(rlx_resolve).

-export([solve_release/3,
         release/5,
         metadata/1,
         format_error/1]).

-include("relx.hrl").
-include("rlx_log.hrl").

-type name() :: atom().
-type vsn() :: string().

-type type() :: permanent | transient | temporary | load | none.
-type incl_apps() :: [name()].

-type app_config() :: name() |
                      {name(), vsn() | type() | incl_apps()} |
                      {name(), type(), incl_apps()} |
                      {name(), vsn(), type() | incl_apps()} |
                      {name(), vsn(), type(), incl_apps()}.

-type application_spec() :: {name(), vsn()} |
                            {name(), vsn(), type() | incl_apps()} |
                            {name(), vsn(), type(), incl_apps()}.

-record(release, {name             :: name(),
                  vsn              :: ec_semver:any_version(),
                  erts             :: undefined | ec_semver:any_version(),
                  realized = false :: boolean(),
                  app_spec         :: [application_spec()] | undefined,
                  apps_config      :: [app_config()],
                  relfile          :: undefined | string(),
                  app_detail = []  :: [rlx_app:t()],

                  %% per-release config values
                  config = []      :: [term()]}).
-type release() :: #release{}.

-export_type([release/0]).

-spec release(name(), vsn(), [app_config()], [rlx_app:t()], term()) -> rlx_release:t().
release(Name, Vsn, AppConfig, World, _Opts) ->
    Release = #release{name=Name,
                       vsn=Vsn,
                       apps_config=AppConfig},
    process_specs(realize_erts(Release), World).

-spec metadata(release()) -> {ok, term()} | {error, term()}.
metadata(#release{name=Name, vsn=Vsn, erts=ErtsVsn, app_spec=AppSpec, realized=Realized}) ->
    case Realized of
        true ->
            {ok, {release, {erlang:atom_to_list(Name), Vsn}, {erts, ErtsVsn}, AppSpec}};
        false ->
            ?RLX_ERROR({not_realized, Name, Vsn})
    end.


-spec process_specs(release(), [rlx_app:t()]) -> {ok, release()}.
process_specs(Rel=#release{apps_config=AppConfig}, World) ->
    IncludedApps = lists:foldl(fun(#{included_applications := I}, Acc) ->
                                       sets:union(sets:from_list(I), Acc)
                               end, sets:new(), World),
    Specs = [create_app_spec(AppConfig, App, IncludedApps) || App <- World],
    {ok, Rel#release{app_spec=Specs,
                     app_detail=World,
                     realized=true}}.

-spec create_app_spec(app_config(), rlx_app:t(), sets:set(atom())) -> application_spec().
create_app_spec(AppConfig, _App=#{name := BinName,
                                  vsn := Vsn}, WorldIncludedApplications) ->
    %% use type=load for included applications
    %% TODO: shouldn't this error if it is found in Applications and IncludedApplications?
    AtomName = rlx_util:to_atom(BinName),
    Type0 = case sets:is_element(AtomName, WorldIncludedApplications) of
                true ->
                    load;
                false ->
                    permanent
            end,

    case find(AtomName, AppConfig) of
        Name when is_atom(Name) ->
            maybe_with_type({rlx_util:to_atom(BinName), Vsn}, Type0);
        {Name, Vsn1} when Vsn1 =:= Vsn ->
            maybe_with_type({Name, Vsn1}, Type0);
        Spec={_, _Vsn1, Type, IncludedApplications} when is_list(IncludedApplications) ,
                                                      Type =:= permanent ;
                                                      Type =:= transient ;
                                                      Type =:= temporary ;
                                                      Type =:= load ;
                                                      Type =:= none ->
            %% TODO: error if Vsn and Vsn1 don't match
            Spec;
        {Name, Type} when Type =:= permanent ;
                          Type =:= transient ;
                          Type =:= temporary ;
                          Type =:= load ;
                          Type =:= none ->
            maybe_with_type({Name, Vsn}, Type);
        {Name, Vsn1, Type} when Type =:= permanent ;
                                Type =:= transient ;
                                Type =:= temporary ;
                                Type =:= load ;
                                Type =:= none ->
            %% TODO: error if Vsn and Vsn1 don't match
            maybe_with_type({Name, Vsn1}, Type);
        {Name, IncludedApplications} when is_list(IncludedApplications) ->
            %% TODO: error if Vsn and Vsn1 don't match
            maybe_with_type({Name, Vsn, IncludedApplications}, Type0);
        _ ->
            %% TODO: throw a real error
            error
    end.

%% keep a clean .rel file by only included non-defaults
maybe_with_type(Tuple, permanent) ->
    Tuple;
maybe_with_type(Tuple, Type) ->
    erlang:insert_element(3, Tuple, Type).

-spec realize_erts(release()) -> release().
realize_erts(Rel=#release{erts=undefined}) ->
    Rel#release{erts=erlang:system_info(version)};
realize_erts(Rel) ->
    Rel.

%%

find(Key, []) ->
    Key;
find(Key, [Key | _]) ->
    Key;
find(Key, [Tuple | _]) when is_tuple(Tuple) ,
                            element(1, Tuple) =:= Key->
    Tuple;
find(Key, [_ | Rest]) ->
    find(Key, Rest).

%% format errors

-spec format_error(ErrorDetail::term()) -> iolist().
format_error(no_goals_specified) ->
    "No goals specified for this release ~n";
format_error({release_erts_error, Dir}) ->
    io_lib:format("Unable to find erts in ~s~n", [Dir]);
format_error({notfound, App}) ->
    io_lib:format("Application needed for release not found: ~p~n", [App]).
%% legacy

solve_release(RelName, RelVsn, State0) ->
    ?log_debug("Solving Release ~p-~s", [RelName, RelVsn]),
    AllApps = rlx_state:available_apps(State0),
    try
        Release =
            case get_realized_release(State0, RelName, RelVsn) of
                undefined ->
                    rlx_state:get_configured_release(State0, RelName, RelVsn);
                {ok, Release0} ->
                    rlx_release:relfile(rlx_state:get_configured_release(State0, RelName, RelVsn),
                                        rlx_release:relfile(Release0))
            end,

        %% get per release config values and override the State with them
        Config = rlx_release:config(Release),
        {ok, State1} = lists:foldl(fun rlx_config_terms:load/2, {ok, State0}, Config),
        Goals = rlx_release:goals(Release),
        case Goals of
            [] ->
                error(?RLX_ERROR(no_goals_specified));
            _ ->
                Pkgs = subset(maps:to_list(Goals), AllApps),
                set_resolved(Release, Pkgs, State1)
        end
    catch
        throw:not_found ->
            error(?RLX_ERROR({release_not_found, {RelName, RelVsn}}))
    end.

subset(Apps, World) ->
    subset(Apps, World, sets:new(), []).

subset([], _World, _Seen, Acc) ->
    Acc;
subset([Goal | Rest], World, Seen, Acc) ->
    {Name, Vsn} = name_version(Goal),
    case sets:is_element(Name, Seen) of
        true ->
            subset(Rest, World, Seen, Acc);
        _ ->
            AppInfo=#{applications := Applications,
                      included_applications := IncludedApplications} =
                case ec_lists:find(fun(App) ->
                                           case Vsn of
                                               undefined ->
                                                   rlx_app_info:name(App) =:= Name;
                                                _ ->
                                                   rlx_app_info:name(App) =:= Name
                                                       andalso rlx_app_info:vsn(App) =:= Vsn
                                           end
                                   end, World) of
                          {ok, A} ->
                              A;
                          error ->
                              error(?RLX_ERROR({notfound, Name}))
                              %% TODO: Support overriding the dirs to search
                              %% precedence: apps > deps > erl_libs > system
                              %% Dir = code:lib_dir(Name),
                              %% case rebar_app_discover:find_app(Dir, valid) of
                              %%     {true, A} ->
                              %%         A;
                              %%     _ ->
                              %%         throw({app_not_found, Name})
                              %% end
                      end,

            subset(Rest ++ Applications ++ IncludedApplications,
                   World,
                   sets:add_element(Name, Seen),
                   Acc ++ [AppInfo])
    end.


set_resolved(Release0, Pkgs, State) ->
    case rlx_release:realize(Release0, Pkgs) of
        {ok, Release1} ->
            ?log_info("Resolved ~p-~s", [rlx_release:name(Release1), rlx_release:vsn(Release1)]),
            ?log_debug(rlx_release:format(Release1)),
            case rlx_state:get(State, include_erts, undefined) of
                IncludeErts when is_atom(IncludeErts) ->
                    {ok, Release1, rlx_state:add_realized_release(State, Release1)};
                ErtsDir ->
                    try
                        [Erts | _] = filelib:wildcard(filename:join(ErtsDir, "erts-*")),
                        [_, ErtsVsn] = rlx_string:lexemes(filename:basename(Erts), "-"),
                        Release2 = rlx_release:erts(Release1, ErtsVsn),
                        {ok, Release2, rlx_state:add_realized_release(State, Release2)}
                    catch
                        _:_ ->
                            ?RLX_ERROR({release_erts_error, ErtsDir})
                    end
            end
    end.

get_realized_release(State, RelName, RelVsn) ->
    try
        Release = rlx_state:get_realized_release(State, RelName, RelVsn),
        {ok, Release}
    catch
        error:{badkey, _} ->
            undefined
    end.

name_version(Name) when is_atom(Name) ->
    {Name, undefined};
name_version({Name, #{vsn := Vsn}}) ->
    {Name, Vsn}.
