-module(emqttd_reg).
-include_lib("emqtt_commons/include/emqtt_internal.hrl").
-include_lib("emqtt_commons/include/types.hrl").

-export([subscribe/3,
         unsubscribe/3,
         subscriptions/1,
         publish/6,
         register_client/2,
         disconnect_client/1,
         match/1]).

-export([register_client__/3,
         route/7]).

-export([emqttd_table_defs/0,
         reset_all_tables/1]).

-export([direct_plugin_exports/1]).

-hook({auth_on_subscribe, only, 3}).
-hook({on_subscribe, all, 3}).
-hook({on_unsubscribe, all, 3}).
-hook({filter_subscribers, every, 5}).

-spec subscribe(username() | plugin_id(),client_id(),[{topic(), qos()}]) ->
    ok | {error, not_allowed | [any(),...]}.
subscribe(User, ClientId, Topics) ->
    emqttd_cluster:if_ready(fun subscribe_/3, [User, ClientId, Topics]).

-spec subscribe_(username() | plugin_id(),client_id(),[{topic(), qos()}]) ->
    'ok' | {'error','not_allowed' | [any(),...]}.
subscribe_(User, ClientId, Topics) ->
    case emqttd_hook:only(auth_on_subscribe, [User, ClientId, Topics]) of
        ok ->
            emqttd_hook:all(on_subscribe, [User, ClientId, Topics]),
            case subscribe_tx(ClientId, Topics, []) of
                [] ->
                    ok;
                Errors ->
                    {error, Errors}
            end;
        not_found ->
            {error, not_allowed}
    end.

-spec subscribe_tx(client_id(),[{topic(),qos()}],[any()]) -> [any()].
subscribe_tx(_, [], Errors) -> Errors;
subscribe_tx(ClientId, [{Topic, Qos}|Rest], Errors) ->
    case mnesia:transaction(fun add_subscriber/3, [Topic, Qos, ClientId]) of
        {atomic, _} ->
            emqttd_msg_store:deliver_retained(self(), Topic, Qos),
            subscribe_tx(ClientId, Rest, Errors);
        {aborted, Reason} ->
            subscribe_tx(ClientId, Rest, [Reason|Errors])
    end.

-spec unsubscribe(username() | plugin_id(),client_id(),[topic()]) -> any().
unsubscribe(User, ClientId, Topics) ->
    emqttd_cluster:if_ready(fun unsubscribe_/3, [User, ClientId, Topics]).

-spec unsubscribe_(username() | plugin_id(),client_id(),[topic()]) -> 'ok'.
unsubscribe_(User, ClientId, Topics) ->
    lists:foreach(fun(Topic) ->
                          {atomic, _} = del_subscriber(Topic, ClientId)
                  end, Topics),
    emqttd_hook:all(on_unsubscribe, [User, ClientId, Topics]),
    ok.

-spec subscriptions(routing_key()) -> [{client_id(), qos()}].
subscriptions(RoutingKey) ->
    subscriptions(match(RoutingKey), []).

-spec subscriptions([#topic{}],_) -> [{client_id(), qos()}].
subscriptions([], Acc) -> Acc;
subscriptions([#topic{name=Topic, node=Node}|Rest], Acc) when Node == node() ->
    subscriptions(Rest,
                  lists:foldl(
                    fun
                        (#subscriber{client=ClientId, qos=Qos}, Acc1) when Qos > 0 ->
                            [{ClientId, Qos}|Acc1];
                              (_, Acc1) ->
                            Acc1
                    end, Acc, mnesia:dirty_read(emqttd_subscriber, Topic)));
subscriptions([_|Rest], Acc) ->
    subscriptions(Rest, Acc).

-spec register_client(client_id(),flag()) -> ok | {error, not_ready}.
register_client(ClientId, CleanSession) ->
    emqttd_cluster:if_ready(fun register_client_/2, [ClientId, CleanSession]).

-spec register_client_(client_id(),flag()) -> 'ok'.
register_client_(ClientId, CleanSession) ->
    Nodes = emqttd_cluster:nodes(),
    lists:foreach(fun(Node) when Node == node() ->
                          register_client__(self(), ClientId, CleanSession);
                     (Node) ->
                          rpc:call(Node, ?MODULE, register_client__, [self(), ClientId, CleanSession])
                  end, Nodes).

-spec register_client__(pid(),client_id(),flag()) -> ok.
register_client__(ClientPid, ClientId, CleanSession) ->
    disconnect_client(ClientId), %% disconnect in case we already have such a client id
    case CleanSession of
        false ->
            emqttd_msg_store:deliver_from_store(ClientId, ClientPid);
        true ->
            %% this will also cleanup the message store
            cleanup_client_(ClientId)
    end,
    gproc:add_local_name({?MODULE, ClientId}),
    ok.

-spec publish(username() | plugin_id(),client_id(), undefined | msg_ref(),
              routing_key(),binary(),flag()) -> 'ok' | {'error',_}.
publish(User, ClientId, MsgId, RoutingKey, Payload, IsRetain)
  when is_list(RoutingKey) and is_binary(Payload) ->
    Ref = make_ref(),
    Caller = {self(), Ref},
    ReqF = fun() ->
                   exit({Ref, publish(User, ClientId, MsgId, RoutingKey, Payload, IsRetain, Caller)})
           end,
    try spawn_monitor(ReqF) of
        {_, MRef} ->
            receive
                Ref ->
                    erlang:demonitor(MRef, [flush]),
                    ok;
                {'DOWN', MRef, process, Reason} ->
                    {error, Reason}
            end
    catch
        error: system_limit = E ->
            {error, E}
    end.


%publish to cluster node.
-spec publish(username() | plugin_id(),client_id(),msg_id(),
              routing_key(),payload(),flag(),{pid(),reference()}) -> ok | {error, _}.
publish(User, ClientId, MsgId, RoutingKey, Payload, IsRetain, Caller) ->
    MatchedTopics = match(RoutingKey),
    case IsRetain of
        true ->
            emqttd_cluster:if_ready(fun publish_/8, [User, ClientId, MsgId, RoutingKey, Payload, IsRetain, MatchedTopics, Caller]);
        false ->
            case check_single_node(node(), MatchedTopics, length(MatchedTopics)) of
                true ->
                    %% in case we have only subscriptions on one single node
                    %% we can deliver the messages even in case of network partitions
                    lists:foreach(fun(#topic{name=Name}) ->
                                          route(User, ClientId, MsgId, Name, RoutingKey, Payload, IsRetain)
                                  end, MatchedTopics),
                    {CallerPid, CallerRef} = Caller,
                    CallerPid ! CallerRef,
                    ok;
                false ->
                    emqttd_cluster:if_ready(fun publish__/8, [User, ClientId, MsgId, RoutingKey, Payload, IsRetain, MatchedTopics, Caller])
            end
    end.

-spec publish_(username() | plugin_id(),client_id(),msg_id(),
               routing_key(),payload(),'true',[#topic{}],{pid(), reference()}) -> 'ok'.
publish_(User, ClientId, MsgId, RoutingKey, Payload, IsRetain = true, MatchedTopics, Caller) ->
    ok = emqttd_msg_store:retain_action(User, ClientId, RoutingKey, Payload),
    publish__(User, ClientId, MsgId, RoutingKey, Payload, IsRetain, MatchedTopics, Caller).

-spec publish__(username() | plugin_id(),client_id(),msg_id(),
                routing_key(),payload(),flag(),[#topic{}],{pid(), reference()}) -> 'ok'.
publish__(User, ClientId, MsgId, RoutingKey, Payload, IsRetain, MatchedTopics, Caller) ->
    {CallerPid, CallerRef} = Caller,
    CallerPid ! CallerRef,
    lists:foreach(
      fun(#topic{name=Name, node=Node}) ->
              case Node == node() of
                  true ->
                      route(User, ClientId, MsgId, Name, RoutingKey, Payload, IsRetain);
                  false ->
                      rpc:call(Node, ?MODULE, route, [User, ClientId, MsgId, Name, RoutingKey, Payload, IsRetain])
              end
      end, MatchedTopics).


-spec check_single_node(atom(),[#topic{}],integer()) -> boolean().
check_single_node(Node, [#topic{node=Node}|Rest], Acc) ->
    check_single_node(Node, Rest, Acc -1);
check_single_node(Node, [_|Rest], Acc) ->
    check_single_node(Node, Rest, Acc);
check_single_node(_, [], 0) -> true;
check_single_node(_, [], _) -> false.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% RPC Callbacks / Maintenance
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec disconnect_client(client_id() | pid()) -> 'ok' | {'error','not_found'}.
disconnect_client(ClientPid) when is_pid(ClientPid) ->
    emqttd_fsm:disconnect(ClientPid),
    ok;
disconnect_client(ClientId) ->
    wait_until_unregistered(ClientId, false).

-spec wait_until_unregistered(client_id(),boolean()) -> {'error','not_found'}.
wait_until_unregistered(ClientId, DisconnectRequested) ->
    case get_client_pid(ClientId) of
        {ok, ClientPid} ->
            case is_process_alive(ClientPid) of
                true when not DisconnectRequested->
                    disconnect_client(ClientPid),
                    wait_until_unregistered(ClientId, true);
                _ ->
                    timer:sleep(100),
                    wait_until_unregistered(ClientId, DisconnectRequested)
            end;
        E -> E
    end.


%route locally, should only be called by publish
-spec route(username() | plugin_id(),client_id(),msg_id(),topic(),
            routing_key(),payload(),flag()) -> 'ok'.
route(SendingUser, SendingClientId, MsgId, Topic, RoutingKey, Payload, IsRetain) ->
    Subscribers = mnesia:dirty_read(emqttd_subscriber, Topic),
    FilteredSubscribers = emqttd_hook:every(filter_subscribers, Subscribers, [SendingUser, SendingClientId, MsgId, RoutingKey, Payload]),
    lists:foreach(fun
                    (#subscriber{qos=Qos, client=ClientId}) when Qos > 0 ->
                          MaybeNewMsgId = emqttd_msg_store:store(SendingUser, SendingClientId, MsgId, RoutingKey, Payload),
                          deliver(ClientId, RoutingKey, Payload, Qos, MaybeNewMsgId, IsRetain);
                    (#subscriber{qos=0, client=ClientId}) ->
                          deliver(ClientId, RoutingKey, Payload, 0, undefined, IsRetain)
                end, FilteredSubscribers).

-spec deliver(client_id(),routing_key(),payload(),
              qos(),msg_ref(),flag()) -> 'ok' | {'error','not_found'}.
deliver(_, _, <<>>, _, Ref, true) ->
    %% <<>> --> retain-delete action, we don't deliver the empty frame
    emqttd_msg_store:deref(Ref),
    ok;
deliver(ClientId, RoutingKey, Payload, Qos, Ref, _IsRetain) ->
    case get_client_pid(ClientId) of
        {ok, ClientPid} ->
            emqttd_fsm:deliver(ClientPid, RoutingKey, Payload, Qos, false, false, Ref);
        _ when Qos > 0 ->
            emqttd_msg_store:defer_deliver(ClientId, Qos, Ref),
            ok;
        _ ->
            ok
    end.

-spec match(routing_key()) -> [#topic{}].
match(Topic) when is_list(Topic) ->
    TrieNodes = mnesia:async_dirty(fun trie_match/1, [emqtt_topic:words(Topic)]),
    Names = [Name || #trie_node{topic=Name} <- TrieNodes, Name=/= undefined],
    lists:flatten([mnesia:dirty_read(emqttd_trie_topic, Name) || Name <- Names]).

-spec emqttd_table_defs() -> [{atom(), [{atom(), any()}]}].
emqttd_table_defs() ->
    [
     {emqttd_trie,[
       {record_name, trie},
       {attributes, record_info(fields, trie)},
       {disc_copies, [node()]},
       {match, #trie{_='_'}}]},
     {emqttd_trie_node,[
       {record_name, trie_node},
       {attributes, record_info(fields, trie_node)},
       {disc_copies, [node()]},
       {match, #trie_node{_='_'}}]},
     {emqttd_trie_topic,[
       {record_name, topic},
       {type, bag},
       {attributes, record_info(fields, topic)},
       {disc_copies, [node()]},
       {match, #topic{_='_'}}]},
     {emqttd_subscriber,[
        {record_name, subscriber},
        {type, bag},
        {attributes, record_info(fields, subscriber)},
        {disc_copies, [node()]},
        {match, #subscriber{_='_'}}]}
].


-spec reset_all_tables([]) -> ok.
reset_all_tables([]) ->
    %% called using emqttd-admin, mainly for test purposes
    %% you don't want to call this during production
    [reset_table(T) || {T,_}<- emqttd_table_defs()],
    ok.

-spec reset_table(atom()) -> ok.
reset_table(Tab) ->
    lists:foreach(fun(Key) ->
                          mnesia:dirty_delete(Tab, Key)
                  end, mnesia:dirty_all_keys(Tab)).


-spec wait_til_ready() -> 'ok'.
wait_til_ready() ->
    case emqttd_cluster:if_ready(fun() -> true end, []) of
        true ->
            ok;
        {error, not_ready} ->
            timer:sleep(100),
            wait_til_ready()
    end.

-spec direct_plugin_exports(module()) -> {function(), function(), function()}.
direct_plugin_exports(Mod) ->
    %% This Function exports a generic Register, Publish, and Subscribe
    %% Fun, that a plugin can use if needed. Currently all functions
    %% block until the cluster is ready.
    ClientId = fun(T) ->
                       base64:encode_to_string(
                         integer_to_binary(
                           erlang:phash2(T)
                          )
                        )
               end,

    RegisterFun =
    fun() ->
            wait_til_ready(),
            CallingPid = self(),
            register_client__(CallingPid, ClientId(CallingPid), true)
    end,

    PublishFun =
    fun(Topic, Payload) ->
            wait_til_ready(),
            CallingPid = self(),
            User = {plugin, Mod, CallingPid},
            ok = publish(User, ClientId(CallingPid), undefined, Topic, Payload, false),
            ok
    end,

    SubscribeFun =
    fun(Topic) ->
            wait_til_ready(),
            CallingPid = self(),
            User = {plugin, Mod, CallingPid},
            ok = subscribe(User, ClientId(CallingPid), [{Topic, 0}]),
            ok
    end,
    {RegisterFun, PublishFun, SubscribeFun}.

-spec add_subscriber(topic(),qos(),client_id()) -> ok | ignore | abort.
add_subscriber(Topic, Qos, ClientId) ->
    mnesia:write(emqttd_subscriber, #subscriber{topic=Topic, qos=Qos, client=ClientId}, write),
    mnesia:write(emqttd_trie_topic, emqtt_topic:new(Topic), write),
    case mnesia:read(emqttd_trie_node, Topic) of
        [TrieNode=#trie_node{topic=undefined}] ->
            mnesia:write(emqttd_trie_node, TrieNode#trie_node{topic=Topic}, write);
        [#trie_node{topic=Topic}] ->
            ignore;
        [] ->
            %add trie path
            [trie_add_path(Triple) || Triple <- emqtt_topic:triples(Topic)],
            %add last node
            mnesia:write(emqttd_trie_node, #trie_node{node_id=Topic, topic=Topic}, write)
    end.


-spec del_subscriber(topic() | '_' ,client_id()) -> {'aborted',_} | {'atomic',ok}.
del_subscriber(Topic, ClientId) ->
    mnesia:transaction(
      fun() ->
              Objs = mnesia:match_object(emqttd_subscriber, #subscriber{topic=Topic, client=ClientId, _='_'}, read),
              lists:foreach(fun(#subscriber{topic=T} = Obj) ->
                                    mnesia:delete_object(emqttd_subscriber, Obj, write),
                                    del_topic(T)
                            end, Objs)
      end).

-spec del_topic(topic()) -> any().
del_topic(Topic) ->
    case mnesia:read(emqttd_subscriber, Topic) of
        [] ->
            TopicRec = emqtt_topic:new(Topic),
            mnesia:delete_object(emqttd_trie_topic, TopicRec, write),
            case mnesia:read(emqttd_trie_topic, Topic) of
                [] -> trie_delete(Topic);
                _ -> ignore
            end;
        _ ->
            ok
    end.

-spec trie_delete(maybe_improper_list()) -> any().
trie_delete(Topic) ->
    case mnesia:read(emqttd_trie_node, Topic) of
        [#trie_node{edge_count=0}] ->
            mnesia:delete({emqttd_trie_node, Topic}),
            trie_delete_path(lists:reverse(emqtt_topic:triples(Topic)));
        [TrieNode] ->
            mnesia:write(emqttd_trie_node, TrieNode#trie_node{topic=Topic}, write);
        [] ->
            ignore
    end.

-spec trie_match(maybe_improper_list()) -> any().
trie_match(Words) ->
    trie_match(root, Words, []).

-spec trie_match(_,maybe_improper_list(),_) -> any().
trie_match(NodeId, [], ResAcc) ->
    mnesia:read(emqttd_trie_node, NodeId) ++ 'trie_match_#'(NodeId, ResAcc);

trie_match(NodeId, [W|Words], ResAcc) ->
    lists:foldl(
      fun(WArg, Acc) ->
              case mnesia:read(emqttd_trie, #trie_edge{node_id=NodeId, word=WArg}) of
                  [#trie{node_id=ChildId}] -> trie_match(ChildId, Words, Acc);
                  [] -> Acc
              end
      end, 'trie_match_#'(NodeId, ResAcc), [W, "+"]).

-spec 'trie_match_#'(_,_) -> any().
'trie_match_#'(NodeId, ResAcc) ->
    case mnesia:read(emqttd_trie, #trie_edge{node_id=NodeId, word="#"}) of
        [#trie{node_id=ChildId}] ->
            mnesia:read(emqttd_trie_node, ChildId) ++ ResAcc;
        [] ->
            ResAcc
    end.

-spec trie_add_path({'root' | [any()],[any()],[any()]}) -> any().
trie_add_path({Node, Word, Child}) ->
    Edge = #trie_edge{node_id=Node, word=Word},
    case mnesia:read(emqttd_trie_node, Node) of
        [TrieNode = #trie_node{edge_count=Count}] ->
            case mnesia:read(emqttd_trie, Edge) of
                [] ->
                    mnesia:write(emqttd_trie_node, TrieNode#trie_node{edge_count=Count+1}, write),
                    mnesia:write(emqttd_trie, #trie{edge=Edge, node_id=Child}, write);
                [_] ->
                    ok
            end;
        [] ->
            mnesia:write(emqttd_trie_node, #trie_node{node_id=Node, edge_count=1}, write),
            mnesia:write(emqttd_trie, #trie{edge=Edge, node_id=Child}, write)
    end.

-spec trie_delete_path([{'root' | [any()],[any()],[any()]}]) -> any().
trie_delete_path([]) ->
    ok;
trie_delete_path([{NodeId, Word, _}|RestPath]) ->
    Edge = #trie_edge{node_id=NodeId, word=Word},
    mnesia:delete({emqttd_trie, Edge}),
    case mnesia:read(emqttd_trie_node, NodeId) of
        [#trie_node{edge_count=1, topic=undefined}] ->
            mnesia:delete({emqttd_trie_node, NodeId}),
            trie_delete_path(RestPath);
        [TrieNode=#trie_node{edge_count=1, topic=_}] ->
            mnesia:write(emqttd_trie_node, TrieNode#trie_node{edge_count=0}, write);
        [TrieNode=#trie_node{edge_count=Count}] ->
            mnesia:write(emqttd_trie_node, TrieNode#trie_node{edge_count=Count-1}, write);
        [] ->
            throw({notfound, NodeId})
    end.


-spec get_client_pid(_) -> {'error','not_found'} | {'ok',_}.
get_client_pid(ClientId) ->
    case gproc:lookup_local_name({?MODULE, ClientId}) of
        undefined ->
            {error, not_found};
        ClientPid ->
            {ok, ClientPid}
    end.

-spec cleanup_client_(client_id()) -> {'atomic','ok'}.
cleanup_client_(ClientId) ->
    emqttd_msg_store:clean_session(ClientId),
    {atomic, ok} = del_subscriber('_', ClientId).
