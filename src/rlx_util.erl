%% -*- erlang-indent-level: 4; indent-tabs-mode: nil; fill-column: 80 -*-
%%% Copyright 2012 Erlware, LLC. All Rights Reserved.
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%---------------------------------------------------------------------------
%%% @author Eric Merritt <ericbmerritt@gmail.com>
%%% @copyright (C) 2012 Erlware, LLC.
%%%
%%% @doc Trivial utility file to help handle common tasks
-module(rlx_util).

-export([relx_sasl_vsn/0,
         parse_vsn/1,
         get_code_paths/2,
         release_output_dir/2,
         to_binary/1,
         to_string/1,
         is_error/1,
         error_reason/1,
         indent/1,
         render/2,
         load_file/3,
         template_files/0]).

-export([os_type/1]).

-define(ONE_LEVEL_INDENT, "     ").

-include("rlx_log.hrl").

relx_sasl_vsn() ->
    application:load(sasl),
    case application:get_key(sasl, vsn) of
        {ok, SaslVsn} ->
            parse_vsn(SaslVsn) > {3,4,1};
        _ ->
            false
    end.

parse_vsn(Vsn) ->
    case re:run(Vsn, "^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?(\\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?$", [{capture, [1,2,3], list}]) of
        {match, [Major, Minor, Patch]} ->
            {list_to_integer(Major), list_to_integer(Minor), list_to_integer(Patch)};
        _ ->
            0
    end.

%% @doc Generates the correct set of code paths for the system.
-spec get_code_paths(rlx_release:t(), file:name()) -> [file:name()].
get_code_paths(Release, OutDir) ->
    LibDir = filename:join(OutDir, "lib"),
    [filename:join([LibDir,
                    erlang:atom_to_list(rlx_app_info:name(App)) ++ "-" ++
                        rlx_app_info:vsn(App), "ebin"]) ||
        App <- rlx_release:applications(Release)].

-spec release_output_dir(rlx_state:t(), rlx_release:t()) -> string().
release_output_dir(State, Release) ->
    OutputDir = rlx_state:base_output_dir(State),
    filename:join([OutputDir,
                   rlx_release:name(Release),
                   "releases",
                   rlx_release:vsn(Release)]).

%% @doc ident to the level specified
-spec indent(non_neg_integer()) -> iolist().
indent(Amount) when erlang:is_integer(Amount) ->
    [?ONE_LEVEL_INDENT || _ <- lists:seq(1, Amount)].

-spec to_binary(iolist() | binary()) -> binary().
to_binary(String) when erlang:is_list(String) ->
    erlang:iolist_to_binary(String);
to_binary(Atom) when erlang:is_atom(Atom) ->
    erlang:atom_to_binary(Atom, utf8);
to_binary(Bin) when erlang:is_binary(Bin) ->
    Bin.

-spec to_string(binary() | string() | atom()) -> string().
to_string(Binary) when erlang:is_binary(Binary) ->
    erlang:binary_to_list(Binary);
to_string(Atom) when erlang:is_atom(Atom) ->
    erlang:atom_to_list(Atom);
to_string(Else) when erlang:is_list(Else) ->
    Else.

%% @doc get the reason for a particular relx error
-spec error_reason(relx:error()) -> any().
error_reason({error, {_, Reason}}) ->
    Reason.
%% @doc check to see if the value is a relx error
-spec is_error(relx:error() | any()) -> boolean().
is_error({error, _}) ->
    true;
is_error(_) ->
    false.

-spec render(binary() | iolist(), proplists:proplist()) ->
                {ok, binary()} | {error, render_failed}.
render(Template, Data) when is_list(Template) ->
    render(rlx_util:to_binary(Template), Data);
render(Template, Data) when is_binary(Template) ->
    case catch bbmustache:render(Template, Data,
                                 [{key_type, atom}]) of
        Bin when is_binary(Bin) -> {ok, Bin};
        _ -> {error, render_failed}
    end.

load_file(Files, escript, Name) ->
    {Name, Bin} = lists:keyfind(Name, 1, Files),
    Bin;
load_file(_Files, file, Name) ->
    {ok, Bin} = file:read_file(Name),
    Bin.

template_files() ->
    find_priv_templates() ++ escript_files().

find_priv_templates() ->
    Files = filelib:wildcard(filename:join([code:priv_dir(relx), "templates", "*"])),
    lists:map(fun(File) ->
                      {ok, Bin} = file:read_file(File),
                      {filename:basename(File), Bin}
              end, Files).

%% Scan the current escript for available files
escript_files() ->
    try
        {ok, Files} = escript_foldl(
                        fun(Name, _, GetBin, Acc) ->
                                [{filename:basename(Name), GetBin()} | Acc]
                        end, [], filename:absname(escript:script_name())),
        Files
    catch
        _:_ ->
            []
    end.

escript_foldl(Fun, Acc, File) ->
    case escript:extract(File, []) of
        {ok, [_Shebang, _Comment, _EmuArgs, Body]} ->
            case Body of
                {source, BeamCode} ->
                    GetInfo = fun() -> file:read_file_info(File) end,
                    GetBin = fun() -> BeamCode end,
                    {ok, Fun(".", GetInfo, GetBin, Acc)};
                {beam, BeamCode} ->
                    GetInfo = fun() -> file:read_file_info(File) end,
                    GetBin = fun() -> BeamCode end,
                    {ok, Fun(".", GetInfo, GetBin, Acc)};
                {archive, ArchiveBin} ->
                    zip:foldl(Fun, Acc, {File, ArchiveBin})
            end;
        {error, _} = Error ->
            Error
    end.

os_type(State) ->
  case include_erts_is_win32(State) of
    true -> {win32,nt};
    false -> os:type()
  end.

include_erts_is_win32(State) ->
  case rlx_state:get(State, include_erts, true) of
    true -> false;
    false -> false;
    Path -> is_win32_erts(Path)
  end.

is_win32_erts(Path) ->
  case filelib:wildcard(filename:join([Path,"bin","erl.exe"])) of
    [] ->
          false;
    _ ->
      ?log_info("Including Erts is win32"),
      true
  end.


