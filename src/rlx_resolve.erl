-module(rlx_resolve).

-export([solve_release/2,
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
                  app_detail = []  :: [rlx_app_info:t()],

                  %% per-release config values
                  config = []      :: [term()]}).
-type release() :: #release{}.

-export_type([release/0]).

%% format errors

-spec format_error(ErrorDetail::term()) -> iolist().
format_error({no_goals_specified, {RelName, RelVsn}}) ->
    io_lib:format("No applications configured to be included in release ~s-~s", [RelName, RelVsn]);
format_error({release_erts_error, Dir}) ->
    io_lib:format("Unable to find erts in ~s", [Dir]);
format_error({release_not_found, {RelName, RelVsn}}) ->
    io_lib:format("No release named ~s of version ~s found in configuration", [RelName, RelVsn]);
format_error({app_not_found, App}) ->
    io_lib:format("Application needed for release not found: ~p", [App]).

solve_release(Release, State0) ->
    RelName = rlx_release:name(Release),
    RelVsn = rlx_release:vsn(Release),
    ?log_debug("Solving Release ~p-~s", [RelName, RelVsn]),
    AllApps = rlx_state:available_apps(State0),
    try
        %% get per release config values and override the State with them
        Config = rlx_release:config(Release),
        {ok, State1} = lists:foldl(fun rlx_config:load/2, {ok, State0}, Config),
        case rlx_release:goals(Release) of
            Goals when map_size(Goals) =:= 0 ->
                erlang:error(?RLX_ERROR({no_goals_specified, {RelName, RelVsn}}));
            Goals ->
                Pkgs = subset(maps:to_list(Goals), AllApps),
                Pkgs1 = remove_exclude_apps(Pkgs, State1),
                set_resolved(Release, Pkgs1, State1)
        end
    catch
        throw:not_found ->
            erlang:error(?RLX_ERROR({release_not_found, {RelName, RelVsn}}))
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
                              error(?RLX_ERROR({app_not_found, Name}))
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
            ?log_debug("~s", [rlx_release:format(Release1)]),
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

name_version(Name) when is_atom(Name) ->
    {Name, undefined};
name_version({Name, #{vsn := Vsn}}) ->
    {Name, Vsn}.

remove_exclude_apps(AllApps, State) ->
    ExcludeApps = rlx_state:exclude_apps(State),
    lists:foldl(fun(AppName, Acc) ->
                        find_and_remove(AppName, Acc)
                end, AllApps, ExcludeApps).

find_and_remove(_, []) ->
    [];
find_and_remove(ExcludeName, [#{name := Name} | Rest]) when ExcludeName =:= Name ->
    Rest;
find_and_remove(ExcludeName, [H | Rest]) ->
    [H | find_and_remove(ExcludeName, Rest)].
