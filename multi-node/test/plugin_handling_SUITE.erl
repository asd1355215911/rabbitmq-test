%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2014 GoPivotal, Inc.  All rights reserved.
%%
-module(plugin_handling_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("systest/include/systest.hrl").

-export([suite/0, all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).
-export([basic_enable/1, transitive_dependency_handling/1,
         offline_must_be_explicit/1, management_extension_handling/1]).

%% Configuration

suite() -> [{timetrap, systest:settings("time_traps.ha_cluster_SUITE")}].

all() ->
    [{group, with_running_nodes},
     management_extension_handling,
     {group, with_offline_nodes}].

groups() ->
    [{with_running_nodes, [shuffle],
      [basic_enable,
       transitive_dependency_handling]},
     {with_offline_nodes, [shuffle],
      [offline_must_be_explicit]}].

%% Setup/Teardown

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(with_offline_nodes=Group, Config) ->
    [rabbit_ha_test_utils:stop_app(Node) ||
        {Node, _} <- systest:list_processes(Group)],
    Config;
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, Config) ->
    {save_config, Config}.

init_per_testcase(TC, Config) ->
    file:delete(enabled_plugins_file()),
    [{Node1, _}, {Node2, _}] = systest:list_processes(plugin_handling),
    Config2 = case TC of
                  management_extension_handling ->
                      rabbit_ha_test_utils:stop_app(Node1),
                      [{stopped, Node1}];
                  _ ->
                      []
              end,
    [{node1, Node1}, {node2, Node2}] ++ Config2 ++ Config.

%% TODO: consider putting mgmt_extension_handling into another group

end_per_testcase(management_extension_handling, _Config) ->
    [{Node1, _}|_] = systest:list_processes(plugin_handling),
    try
        %% this *can* fail in the testcase, if not it'll fail here
        %% and we want to remain as oblivious as we possibly can
        rabbit_ha_test_utils:start_app(Node1),
        ok
    catch _:_ -> ok
    end;
end_per_testcase(_, _) ->
    ok.

%% Test Cases

basic_enable(Config) ->
    SUT = systest:active_sut(Config),
    [{A, _ARef},
     {_B, _BRef}] = systest:list_processes(SUT),
    enable(rabbitmq_shovel, A),
    verify_app_running(rabbitmq_shovel, A),
    ok.

transitive_dependency_handling(Config) ->
    SUT = systest:active_sut(Config),
    [{A, _ARef},
     {_B, _BRef}] = systest:list_processes(SUT),
    [begin
         enable(P, A),
         verify_app_running(P, A)
     end  || P <- [rabbitmq_shovel, rabbitmq_federation]],
    disable(rabbitmq_shovel, A),
    verify_app_not_running(rabbitmq_shovel, A),
    verify_app_running(amqp_client, A),  %% federation requires amqp_client
    ok.

offline_must_be_explicit(Config) ->
    SUT = systest:active_sut(Config),
    [{A, _ARef},
     {_B, _BRef}] = systest:list_processes(SUT),
    rabbit_ha_test_utils:stop_app(A),
    try
        enable(rabbitmq_shovel, A),
        exit({node_offline, "without --offline, rabbitmq-plugins should crash"})
    catch _:{error_string, _} -> ok
    after
        rabbit_ha_test_utils:start_app(A)
    end.

management_extension_handling(Config) ->
    SUT = systest:active_sut(Config),
    [{C, _ARef},
     {_B, _BRef}] = systest:list_processes(SUT),
    enable_offline(rabbitmq_management, C),
    enable_offline(rabbitmq_shovel_management, C),
    rabbit_ha_test_utils:start_app(C),
    verify_app_running(rabbitmq_shovel_management, C),
    disable(rabbitmq_shovel_management, C),
    verify_app_not_running(rabbitmq_shovel_management, C),
    ok.

verify_app_running(App, Node) ->
    {App, _, _} = lists:keyfind(App, 1, get_running_apps(Node)).

verify_app_not_running(App, Node) ->
    false = lists:keyfind(App, 1, get_running_apps(Node)).

get_running_apps(Node) ->
    rpc:call(Node, rabbit_misc, which_applications, []).

enable(Plugin, Node) ->
    plugin_action(enable, Node, [atom_to_list(Plugin)]).

disable(Plugin, Node) ->
    plugin_action(disable, Node, [atom_to_list(Plugin)]).

enable_offline(Plugin, Node) ->
    plugin_action(enable, Node, [atom_to_list(Plugin)],
                  [{"--offline", true}]).

plugin_action(Command, Node, Args) ->
    plugin_action(Command, Node, Args, []).

plugin_action(Command, Node, Args, Opts) ->
    File = enabled_plugins_file(),
    {_, PDir} = systest:env("RABBITMQ_BROKER_DIR"),
    Dir = filename:join(PDir, "plugins"),
    rabbit_plugins_main:action(Command, Node, Args, Opts, File, Dir).

enabled_plugins_file() ->
    {_, PkgDir} = systest:env("PACKAGE_DIR"),
    filename:join([PkgDir, "resources", "enabled-plugins"]).

