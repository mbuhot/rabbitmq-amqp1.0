%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_amqp1_0_reader).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").
-include("rabbit_amqp1_0.hrl").

-export([start_link/3, info_keys/0, info/1, info/2, shutdown/2]).

-export([system_continue/3, system_terminate/4, system_code_change/4]).

-export([init/4, mainloop/2]).

-export([conserve_memory/2, server_properties/0]).

-export([analyze_frame/3]).

-export([emit_stats/1]).

-define(HANDSHAKE_TIMEOUT, 10).
-define(NORMAL_TIMEOUT, 3).
-define(CLOSING_TIMEOUT, 1).
-define(CHANNEL_TERMINATION_TIMEOUT, 3).
-define(SILENT_CLOSE_DELAY, 3).
-define(FRAME_MAX, 0).

%---------------------------------------------------------------------------

-record(v1, {parent, sock, connection, callback, recv_length, recv_ref,
             connection_state, queue_collector, heartbeater, stats_timer,
             channel_sup_sup_pid, start_heartbeat_fun}).

-define(STATISTICS_KEYS, [pid, recv_oct, recv_cnt, send_oct, send_cnt,
                          send_pend, state, channels]).

-define(CREATION_EVENT_KEYS, [pid, address, port, peer_address, peer_port, ssl,
                              peer_cert_subject, peer_cert_issuer,
                              peer_cert_validity,
                              protocol, user, vhost, timeout, frame_max,
                              client_properties]).

-define(INFO_KEYS, ?CREATION_EVENT_KEYS ++ ?STATISTICS_KEYS -- [pid]).

%% connection lifecycle
%%
%% all state transitions and terminations are marked with *...*
%%
%% The lifecycle begins with: start handshake_timeout timer, *pre-init*
%%
%% all states, unless specified otherwise:
%%   socket error -> *exit*
%%   socket close -> *throw*
%%   writer send failure -> *throw*
%%   forced termination -> *exit*
%%   handshake_timeout -> *throw*
%%
%% AMQP 1.0 connection state machine:
%%
%% In general, we react to what the client sends us; so we take all
%% the branches in the connection state diagram labelled R:something,
%% where there is a choice.  I've kept the 0-x names for the states,
%% and noted the 1.0 equivalent alongside.
%%
%% pre-init (== start):
%%   receive protocol header -> send protocol header, *starting*
%% starting (== hdr_exch):
%%   receive connection.open -> send connection.open, *running*
%% running:
%%   receive connection.close ->
%%     tell channels to terminate gracefully
%%     if no channels then send connection.close, start
%%        terminate_connection timer, *closed*
%%     else *closing*
%%   forced termination
%%   -> wait for channels to terminate forcefully, start
%%      terminate_connection timer, send connection.close, *exit*
%%   channel exit with hard error
%%   -> log error, wait for channels to terminate forcefully, start
%%      terminate_connection timer, send connection.close, *closed*
%%   channel exit with soft error
%%   -> log error, mark channel as closing, *running*
%%   handshake_timeout -> ignore, *running*
%%   heartbeat timeout -> *throw*
%%   conserve_memory=true -> *blocking*
%% (AMQP 1.0 TODO ff)
%% blocking:
%%   conserve_memory=true -> *blocking*
%%   conserve_memory=false -> *running*
%%   receive a method frame for a content-bearing method
%%   -> process, stop receiving, *blocked*
%%   ...rest same as 'running'
%% blocked:
%%   conserve_memory=true -> *blocked*
%%   conserve_memory=false -> resume receiving, *running*
%%   ...rest same as 'running'
%% closing:
%%   socket close -> *terminate*
%%   receive connection.close -> send connection.close,
%%     *closing*
%%   receive frame -> ignore, *closing*
%%   handshake_timeout -> ignore, *closing*
%%   heartbeat timeout -> *throw*
%%   channel exit with hard error
%%   -> log error, wait for channels to terminate forcefully, start
%%      terminate_connection timer, send connection.close, *closed*
%%   channel exit with soft error
%%   -> log error, mark channel as closing
%%      if last channel to exit then send connection.close,
%%         start terminate_connection timer, *closed*
%%      else *closing*
%%   channel exits normally
%%   -> if last channel to exit then send connection.close,
%%      start terminate_connection timer, *closed*
%% closed (== close_sent):
%%   socket close -> *terminate*
%%   receive connection.close -> send connection.close,
%%     *closed*
%%   receive connection.close -> self() ! terminate_connection,
%%     *closed*
%%   receive frame -> ignore, *closed*
%%   terminate_connection timeout -> *terminate*
%%   handshake_timeout -> ignore, *closed*
%%   heartbeat timeout -> *throw*
%%   channel exit -> log error, *closed*
%%
%% TODO: refactor the code so that the above is obvious

-define(IS_RUNNING(State),
        (State#v1.connection_state =:= running orelse
         State#v1.connection_state =:= blocking orelse
         State#v1.connection_state =:= blocked)).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(start_link/3 :: (pid(), pid(), rabbit_heartbeat:start_heartbeat_fun()) ->
                           rabbit_types:ok(pid())).
-spec(info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(info/1 :: (pid()) -> rabbit_types:infos()).
-spec(info/2 :: (pid(), rabbit_types:info_keys()) -> rabbit_types:infos()).
-spec(emit_stats/1 :: (pid()) -> 'ok').
-spec(shutdown/2 :: (pid(), string()) -> 'ok').
-spec(conserve_memory/2 :: (pid(), boolean()) -> 'ok').
-spec(server_properties/0 :: () -> rabbit_framing:amqp_table()).

%% These specs only exists to add no_return() to keep dialyzer happy
-spec(init/4 :: (pid(), pid(), pid(), rabbit_heartbeat:start_heartbeat_fun())
                -> no_return()).
-spec(start_connection/7 ::
        (pid(), pid(), pid(), rabbit_heartbeat:start_heartbeat_fun(), any(),
         rabbit_net:socket(),
         fun ((rabbit_net:socket()) ->
                     rabbit_types:ok_or_error2(
                       rabbit_net:socket(), any()))) -> no_return()).

-endif.

%%--------------------------------------------------------------------------

start_link(ChannelSupSupPid, Collector, StartHeartbeatFun) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [self(), ChannelSupSupPid,
                                             Collector, StartHeartbeatFun])}.

shutdown(Pid, Explanation) ->
    gen_server:call(Pid, {shutdown, Explanation}, infinity).

init(Parent, ChannelSupSupPid, Collector, StartHeartbeatFun) ->
    Deb = sys:debug_options([]),
    receive
        {go, Sock, SockTransform} ->
            start_connection(
              Parent, ChannelSupSupPid, Collector, StartHeartbeatFun, Deb, Sock,
              SockTransform)
    end.

system_continue(Parent, Deb, State) ->
    ?MODULE:mainloop(Deb, State#v1{parent = Parent}).

system_terminate(Reason, _Parent, _Deb, _State) ->
    exit(Reason).

system_code_change(Misc, _Module, _OldVsn, _Extra) ->
    {ok, Misc}.

info_keys() -> ?INFO_KEYS.

info(Pid) ->
    gen_server:call(Pid, info, infinity).

info(Pid, Items) ->
    case gen_server:call(Pid, {info, Items}, infinity) of
        {ok, Res}      -> Res;
        {error, Error} -> throw(Error)
    end.

emit_stats(Pid) ->
    gen_server:cast(Pid, emit_stats).

conserve_memory(Pid, Conserve) ->
    Pid ! {conserve_memory, Conserve},
    ok.

server_properties() ->
    {ok, Product} = application:get_key(rabbit, id),
    {ok, Version} = application:get_key(rabbit, vsn),

    %% Get any configuration-specified server properties
    {ok, RawConfigServerProps} = application:get_env(rabbit,
                                                     server_properties),

    %% Normalize the simplifed (2-tuple) and unsimplified (3-tuple) forms
    %% from the config and merge them with the generated built-in properties
    NormalizedConfigServerProps =
        [case X of
             {KeyAtom, Value} -> {list_to_binary(atom_to_list(KeyAtom)),
                                  longstr,
                                  list_to_binary(Value)};
             {BinKey, Type, Value} -> {BinKey, Type, Value}
         end || X <- RawConfigServerProps ++
                    [{product,     Product},
                     {version,     Version},
                     {platform,    "Erlang/OTP"},
                     {copyright,   ?COPYRIGHT_MESSAGE},
                     {information, ?INFORMATION_MESSAGE}]],

    %% Filter duplicated properties in favor of config file provided values
    lists:usort(fun ({K1,_,_}, {K2,_,_}) -> K1 =< K2 end,
                NormalizedConfigServerProps).

inet_op(F) -> rabbit_misc:throw_on_error(inet_error, F).

socket_op(Sock, Fun) ->
    case Fun(Sock) of
        {ok, Res}       -> Res;
        {error, Reason} -> rabbit_log:error("error on TCP connection ~p:~p~n",
                                            [self(), Reason]),
                           rabbit_log:info("closing TCP connection ~p~n",
                                           [self()]),
                           exit(normal)
    end.

start_connection(Parent, ChannelSupSupPid, Collector, StartHeartbeatFun, Deb,
                 Sock, SockTransform) ->
    process_flag(trap_exit, true),
    {PeerAddress, PeerPort} = socket_op(Sock, fun rabbit_net:peername/1),
    PeerAddressS = inet_parse:ntoa(PeerAddress),
    rabbit_log:info("starting TCP connection ~p from ~s:~p~n",
                    [self(), PeerAddressS, PeerPort]),
    ClientSock = socket_op(Sock, SockTransform),
    erlang:send_after(?HANDSHAKE_TIMEOUT * 1000, self(),
                      handshake_timeout),
    try
        mainloop(Deb, switch_callback(
                        #v1{parent              = Parent,
                            sock                = ClientSock,
                            connection          = #connection{
                              protocol           = none,
                              user               = none,
                              timeout_sec        = ?HANDSHAKE_TIMEOUT,
                              frame_max          = ?FRAME_MIN_SIZE,
                              vhost              = none,
                              client_properties  = none},
                            callback            = uninitialized_callback,
                            recv_length         = 0,
                            recv_ref            = none,
                            connection_state    = pre_init,
                            queue_collector     = Collector,
                            heartbeater         = none,
                            stats_timer         =
                                rabbit_event:init_stats_timer(),
                            channel_sup_sup_pid = ChannelSupSupPid,
                            start_heartbeat_fun = StartHeartbeatFun
                           },
                        handshake, 8))
    catch
        Ex -> (if Ex == connection_closed_abruptly ->
                       fun rabbit_log:warning/2;
                  true ->
                       fun rabbit_log:error/2
               end)("exception on TCP connection ~p from ~s:~p~n~p~n",
                    [self(), PeerAddressS, PeerPort, Ex])
    after
        rabbit_log:info("closing TCP connection ~p from ~s:~p~n",
                        [self(), PeerAddressS, PeerPort]),
        %% We don't close the socket explicitly. The reader is the
        %% controlling process and hence its termination will close
        %% the socket. Furthermore, gen_tcp:close/1 waits for pending
        %% output to be sent, which results in unnecessary delays.
        %%
        %% gen_tcp:close(ClientSock),
        rabbit_event:notify(connection_closed, [{pid, self()}])
    end,
    done.

mainloop(Deb, State = #v1{parent = Parent, sock= Sock, recv_ref = Ref}) ->
    receive
        {inet_async, Sock, Ref, {ok, Data}} ->
            ?DEBUG("(bytes ~p)~n", [Data]),
            mainloop(Deb, handle_input(State#v1.callback, Data,
                                       State#v1{recv_ref = none}));
        {inet_async, Sock, Ref, {error, closed}} ->
            if State#v1.connection_state =:= closed ->
                    State;
               true ->
                    throw(connection_closed_abruptly)
            end;
        {inet_async, Sock, Ref, {error, Reason}} ->
            throw({inet_error, Reason});
        {conserve_memory, Conserve} ->
            mainloop(Deb, internal_conserve_memory(Conserve, State));
        {'EXIT', Parent, Reason} ->
            terminate(io_lib:format("broker forced connection closure "
                                    "with reason '~w'", [Reason]), State),
            %% this is what we are expected to do according to
            %% http://www.erlang.org/doc/man/sys.html
            %%
            %% If we wanted to be *really* nice we should wait for a
            %% while for clients to close the socket at their end,
            %% just as we do in the ordinary error case. However,
            %% since this termination is initiated by our parent it is
            %% probably more important to exit quickly.
            exit(Reason);
        {channel_exit, _Chan, E = {writer, send_failed, _Error}} ->
            throw(E);
        {channel_exit, ChannelOrFrPid, Reason} ->
            mainloop(Deb, handle_channel_exit(ChannelOrFrPid, Reason, State));
        {'DOWN', _MRef, process, ChSupPid, Reason} ->
            mainloop(Deb, handle_dependent_exit(ChSupPid, Reason, State));
        terminate_connection ->
            State;
        handshake_timeout ->
            if ?IS_RUNNING(State) orelse
               State#v1.connection_state =:= closing orelse
               State#v1.connection_state =:= closed ->
                    mainloop(Deb, State);
               true ->
                    throw({handshake_timeout, State#v1.callback})
            end;
        timeout ->
            throw({timeout, State#v1.connection_state});
        {'$gen_call', From, {shutdown, Explanation}} ->
            {ForceTermination, NewState} = terminate(Explanation, State),
            gen_server:reply(From, ok),
            case ForceTermination of
                force  -> ok;
                normal -> mainloop(Deb, NewState)
            end;
        {'$gen_call', From, info} ->
            gen_server:reply(From, infos(?INFO_KEYS, State)),
            mainloop(Deb, State);
        {'$gen_call', From, {info, Items}} ->
            gen_server:reply(From, try {ok, infos(Items, State)}
                                   catch Error -> {error, Error}
                                   end),
            mainloop(Deb, State);
        {'$gen_cast', emit_stats} ->
            State1 = internal_emit_stats(State),
            mainloop(Deb, State1);
        {system, From, Request} ->
            sys:handle_system_msg(Request, From,
                                  Parent, ?MODULE, Deb, State);
        Other ->
            %% internal error -> something worth dying for
            exit({unexpected_message, Other})
    end.

switch_callback(State = #v1{connection_state = blocked,
                            heartbeater = Heartbeater}, Callback, Length) ->
    ok = rabbit_heartbeat:pause_monitor(Heartbeater),
    State#v1{callback = Callback, recv_length = Length, recv_ref = none};
switch_callback(State, Callback, Length) ->
    Ref = inet_op(fun () -> rabbit_net:async_recv(
                              State#v1.sock, Length, infinity) end),
    State#v1{callback = Callback, recv_length = Length, recv_ref = Ref}.

terminate(Explanation, State) when ?IS_RUNNING(State) ->
    {normal, send_exception(State, 0,
                            rabbit_misc:amqp_error(
                              connection_forced, Explanation, [], none))};
terminate(_Explanation, State) ->
    {force, State}.

internal_conserve_memory(true,  State = #v1{connection_state = running}) ->
    State#v1{connection_state = blocking};
internal_conserve_memory(false, State = #v1{connection_state = blocking}) ->
    State#v1{connection_state = running};
internal_conserve_memory(false, State = #v1{connection_state = blocked,
                                            heartbeater      = Heartbeater,
                                            callback         = Callback,
                                            recv_length      = Length,
                                            recv_ref         = none}) ->
    ok = rabbit_heartbeat:resume_monitor(Heartbeater),
    switch_callback(State#v1{connection_state = running}, Callback, Length);
internal_conserve_memory(_Conserve, State) ->
    State.

close_connection(State = #v1{queue_collector = Collector,
                             connection = #connection{
                               timeout_sec = TimeoutSec}}) ->
    %% The spec says "Exclusive queues may only be accessed by the
    %% current connection, and are deleted when that connection
    %% closes."  This does not strictly imply synchrony, but in
    %% practice it seems to be what people assume.
    rabbit_queue_collector:delete_all(Collector),
    %% We terminate the connection after the specified interval, but
    %% no later than ?CLOSING_TIMEOUT seconds.
    TimeoutMillisec =
        1000 * if TimeoutSec > 0 andalso
                  TimeoutSec < ?CLOSING_TIMEOUT -> TimeoutSec;
                  true -> ?CLOSING_TIMEOUT
               end,
    erlang:send_after(TimeoutMillisec, self(), terminate_connection),
    State#v1{connection_state = closed}.

close_channel(Channel, State) ->
    put({channel, Channel}, closing),
    State.

handle_channel_exit(ChFrPid, Reason, State) when is_pid(ChFrPid) ->
    {channel, Channel} = get({ch_fr_pid, ChFrPid}),
    handle_exception(State, Channel, Reason);
handle_channel_exit(Channel, Reason, State) ->
    handle_exception(State, Channel, Reason).

handle_dependent_exit(ChSupPid, Reason, State) ->
    case termination_kind(Reason) of
        controlled ->
            case erase({ch_sup_pid, ChSupPid}) of
                undefined                                -> ok;
                {_Channel, {ch_fr_pid, _ChFrPid} = ChFr} -> erase(ChFr)
            end,
            maybe_close(State);
        uncontrolled ->
            case channel_cleanup(ChSupPid) of
                undefined ->
                    exit({abnormal_dependent_exit, ChSupPid, Reason});
                Channel ->
                    maybe_close(handle_exception(State, Channel, Reason))
            end
    end.

channel_cleanup(ChSupPid) ->
    case get({ch_sup_pid, ChSupPid}) of
        undefined                  -> undefined;
        {{channel, Channel}, ChFr} -> erase({channel, Channel}),
                                      erase(ChFr),
                                      erase({ch_sup_pid, ChSupPid}),
                                      Channel
    end.

all_channels() -> [ChFrPid || {{ch_sup_pid, _ChSupPid},
                               {_Channel, {ch_fr_pid, ChFrPid}}} <- get()].

terminate_channels() ->
    NChannels =
        length([rabbit_framing_channel:shutdown(ChFrPid)
                || ChFrPid <- all_channels()]),
    if NChannels > 0 ->
            Timeout = 1000 * ?CHANNEL_TERMINATION_TIMEOUT * NChannels,
            TimerRef = erlang:send_after(Timeout, self(), cancel_wait),
            wait_for_channel_termination(NChannels, TimerRef);
       true -> ok
    end.

wait_for_channel_termination(0, TimerRef) ->
    case erlang:cancel_timer(TimerRef) of
        false -> receive
                     cancel_wait -> ok
                 end;
        _     -> ok
    end;

wait_for_channel_termination(N, TimerRef) ->
    receive
        {'DOWN', _MRef, process, ChSupPid, Reason} ->
            case channel_cleanup(ChSupPid) of
                undefined ->
                    exit({abnormal_dependent_exit, ChSupPid, Reason});
                Channel ->
                    case termination_kind(Reason) of
                        controlled ->
                            ok;
                        uncontrolled ->
                            rabbit_log:error(
                              "connection ~p, channel ~p - "
                              "error while terminating:~n~p~n",
                              [self(), Channel, Reason])
                    end,
                    wait_for_channel_termination(N-1, TimerRef)
            end;
        cancel_wait ->
            exit(channel_termination_timeout)
    end.

maybe_close(State = #v1{connection_state = closing,
                        connection = #connection{protocol = Protocol},
                        sock = Sock}) ->
    case all_channels() of
        [] ->
            NewState = close_connection(State),
            ok = case Protocol of
                     rabbit_amqp1_0_framing ->
                         send_on_channel0(Sock, #'v1_0.close'{}, rabbit_amqp1_0_framing);
                     Protocol1 ->
                         send_on_channel0(Sock, #'connection.close_ok'{}, Protocol1)
                 end,
            NewState;
        _  -> State
    end;
maybe_close(State) ->
    State.

termination_kind(normal)            -> controlled;
termination_kind(shutdown)          -> controlled;
termination_kind({shutdown, _Term}) -> controlled;
termination_kind(_)                 -> uncontrolled.

handle_frame(Type, 0, Payload,
             State = #v1{connection_state = CS,
                         connection = #connection{protocol = Protocol}})
  when CS =:= closing; CS =:= closed ->
    case analyze_frame(Type, Payload, Protocol) of
        {method, MethodName, FieldsBin} ->
            handle_method0(MethodName, FieldsBin, State);
        _Other -> State
    end;
handle_frame(_Type, _Channel, _Payload, State = #v1{connection_state = CS})
  when CS =:= closing; CS =:= closed ->
    State;
handle_frame(Type, 0, Payload,
             State = #v1{connection = #connection{protocol = Protocol}}) ->
    case analyze_frame(Type, Payload, Protocol) of
        error     -> throw({unknown_frame, 0, Type, Payload});
        heartbeat -> State;
        {method, MethodName, FieldsBin} ->
            handle_method0(MethodName, FieldsBin, State);
        Other -> throw({unexpected_frame_on_channel0, Other})
    end;
handle_frame(Type, Channel, Payload,
             State = #v1{connection = #connection{protocol = Protocol}}) ->
    case analyze_frame(Type, Payload, Protocol) of
        error         -> throw({unknown_frame, Channel, Type, Payload});
        heartbeat     -> throw({unexpected_heartbeat_frame, Channel});
        AnalyzedFrame ->
            case get({channel, Channel}) of
                {ch_fr_pid, ChFrPid} ->
                    ok = rabbit_framing_channel:process(ChFrPid, AnalyzedFrame),
                    case AnalyzedFrame of
                        {method, 'channel.close', _} ->
                            erase({channel, Channel}),
                            State;
                        {method, MethodName, _} ->
                            case (State#v1.connection_state =:= blocking andalso
                                  Protocol:method_has_content(MethodName)) of
                                true  -> State#v1{connection_state = blocked};
                                false -> State
                            end;
                        _ ->
                            State
                    end;
                closing ->
                    %% According to the spec, after sending a
                    %% channel.close we must ignore all frames except
                    %% channel.close and channel.close_ok.  In the
                    %% event of a channel.close, we should send back a
                    %% channel.close_ok.
                    case AnalyzedFrame of
                        {method, 'channel.close_ok', _} ->
                            erase({channel, Channel});
                        {method, 'channel.close', _} ->
                            %% We're already closing this channel, so
                            %% there's no cleanup to do (notify
                            %% queues, etc.)
                            ok = rabbit_writer:send_command(State#v1.sock,
                                                            #'channel.close_ok'{});
                        _ -> ok
                    end,
                    State;
                undefined ->
                    case ?IS_RUNNING(State) of
                        true  -> ok = send_to_new_channel(
                                        Channel, AnalyzedFrame, State),
                                 State;
                        false -> throw({channel_frame_while_starting,
                                        Channel, State#v1.connection_state,
                                        AnalyzedFrame})
                    end
            end
    end.

analyze_frame(?FRAME_METHOD,
              <<ClassId:16, MethodId:16, MethodFields/binary>>,
              Protocol) ->
    MethodName = Protocol:lookup_method_name({ClassId, MethodId}),
    {method, MethodName, MethodFields};
analyze_frame(?FRAME_HEADER,
              <<ClassId:16, Weight:16, BodySize:64, Properties/binary>>,
              _Protocol) ->
    {content_header, ClassId, Weight, BodySize, Properties};
analyze_frame(?FRAME_BODY, Body, _Protocol) ->
    {content_body, Body};
analyze_frame(?FRAME_HEARTBEAT, <<>>, _Protocol) ->
    heartbeat;
analyze_frame(_Type, _Body, _Protocol) ->
    error.

%% ----------------------------------------
%% AMQP 1.0 frame handlers

is_connection_frame(#'v1_0.open'{})  -> true;
is_connection_frame(#'v1_0.close'{}) -> true;
is_connection_frame(_)               -> false.

%% FIXME Handle depending on connection state
%% TODO It'd be nice to only decode up to the descriptor

%% Nothing specifies that connection methods have to be on a
%% particular channel.
handle_1_0_frame(_Channel, Payload,
                 State = #v1{ connection_state = CS}) when
      CS =:= closing; CS =:= closed ->
    Frame = rabbit_amqp1_0_framing:decode(
              rabbit_amqp1_0_binary_parser:parse(Payload)),
    ?DEBUG("1.0 frame decoded: ~p~n", [Frame]),
    case is_connection_frame(Frame) of
        true  -> handle_1_0_connection_frame(Frame, State);
        false -> State
    end;
handle_1_0_frame(Channel, Payload,
                 State = #v1{ connection_state = CS}) ->
    Frame = rabbit_amqp1_0_framing:decode(
              rabbit_amqp1_0_binary_parser:parse(Payload)),
    ?DEBUG("1.0 frame decoded: ~p~n", [Frame]),
    case is_connection_frame(Frame) of
        true  -> handle_1_0_connection_frame(Frame, State);
        false -> handle_1_0_session_frame(Channel, Frame, State)
    end.

handle_1_0_connection_frame(#'v1_0.open'{ heartbeat_interval = Interval,
                                          max_frame_size = ClientFrameMax,
                                          hostname = _Hostname,
                                          properties = Props },
                            State = #v1{
                              start_heartbeat_fun = SHF,
                              stats_timer = StatsTimer,
                              connection_state = starting,
                              connection = Connection,
                              sock = Sock}) ->
    %% TODO channel_max?
    ClientProps = case Props of
                      undefined -> [];
                      {map, Ps} -> Ps
                  end,
    ClientHeartbeat = case Interval of
                          undefined -> 0;
                          {_, HB} -> HB
                      end,
    FrameMax = case ClientFrameMax of
                   undefined -> 0;
                   {_, FM} -> FM
               end,
    State1 =
        if (FrameMax /= 0) and (FrameMax < ?FRAME_MIN_SIZE) ->
                rabbit_misc:protocol_error(
                  not_allowed, "frame_max=~w < ~w min size",
                  [FrameMax, ?FRAME_MIN_SIZE]);
           (?FRAME_MAX /= 0) and (FrameMax > ?FRAME_MAX) ->
                rabbit_misc:protocol_error(
                  not_allowed, "frame_max=~w > ~w max size",
                  [FrameMax, ?FRAME_MAX]);
           true ->
            SendFun =
                    fun() ->
                            Frame =
                                rabbit_amqp1_0_binary_generator:build_heartbeat_frame(),
                            catch rabbit_net:send(Sock, Frame)
                    end,

                Parent = self(),
                ReceiveFun =
                    fun() ->
                            Parent ! timeout
                    end,
                Heartbeater = SHF(Sock, ClientHeartbeat, SendFun,
                                  ClientHeartbeat, ReceiveFun),
                State#v1{connection_state = running,
                         connection = Connection#connection{
                                        client_properties = ClientProps,
                                        vhost = <<"/">>, %% FIXME relate to hostname
                                        timeout_sec = ClientHeartbeat,
                                        frame_max = FrameMax},
                         heartbeater = Heartbeater}
        end,
    ok = send_on_channel0(
           Sock,
           #'v1_0.open'{channel_max = {ushort, 0},
                        max_frame_size = {uint, FrameMax},
                        container_id = {utf8, list_to_binary(atom_to_list(node()))},
                        heartbeat_interval = {uint, ClientHeartbeat}},
           rabbit_amqp1_0_framing),
    State2 = internal_conserve_memory(
               rabbit_alarm:register(self(), {?MODULE, conserve_memory, []}),
               State1),
    rabbit_event:notify(connection_created,
                        infos(?CREATION_EVENT_KEYS, State2)),
    rabbit_event:if_enabled(StatsTimer,
                            fun() -> internal_emit_stats(State2) end),
    State2;

handle_1_0_connection_frame(Frame = #'v1_0.close'{},
                             State = #v1{ sock = Sock }) ->
    lists:foreach(fun rabbit_framing_channel:shutdown/1, all_channels()),
    maybe_close(State#v1{connection_state = closing}).

handle_1_0_session_frame(Channel, Frame,
                         State = #v1{ sock = Sock,
                                      connection = #connection{
                                        frame_max = FrameMax }}) ->
    case get({channel, Channel}) of
        {ch_fr_pid, SessionPid} ->
            ok = rabbit_amqp1_0_session:process_frame(SessionPid, Frame),
            case Frame of
                #'v1_0.end'{} ->
                    erase({channel, Channel}),
                    State;
                #'v1_0.transfer'{} ->
                    case (State#v1.connection_state =:= blocking) of
                        true  -> State#v1{connection_state = blocked};
                        false -> State
                    end;
                _ ->
                    State
            end;
        closing ->
            case Frame of
                #'v1_0.end'{} ->
                    erase({channel, Channel});
                _Else ->
                    ok
            end,
            State;
        undefined ->
            case ?IS_RUNNING(State) of
                true ->
                    ok = send_to_new_1_0_session(Channel, Frame, State),
                    State;
                false ->
                    throw({channel_frame_while_starting,
                           Channel, State#v1.connection_state,
                           Frame})
            end
    end.

handle_input(frame_header, <<Type:8,Channel:16,PayloadSize:32>>, State) ->
    ensure_stats_timer(
      switch_callback(State, {frame_payload, Type, Channel, PayloadSize},
                      PayloadSize + 1));

handle_input({frame_payload, Type, Channel, PayloadSize},
             PayloadAndMarker, State) ->
    case PayloadAndMarker of
        <<Payload:PayloadSize/binary, ?FRAME_END>> ->
            handle_frame(Type, Channel, Payload,
                         switch_callback(State, frame_header, 7));
        _ ->
            throw({bad_payload, Type, Channel, PayloadSize, PayloadAndMarker})
    end;

handle_input(frame_header_1_0, <<Size:32, DOff:8, Type:8, Channel:16>>,
             State) when DOff >= 2 andalso Type == 0 ->
    ?DEBUG("1.0 frame header: doff: ~p size: ~p~n", [DOff, Size]),
    case Size of
        0 ->
            {State, frame_header_1_0, 8}; %% heartbeat
        _ ->
            ensure_stats_timer(
              switch_callback(State, {frame_payload_1_0, DOff, Channel}, Size - 8))
    end;
handle_input(frame_header_1_0, Malformed, State) ->
    throw({bad_1_0_header, Malformed});
handle_input({frame_payload_1_0, DOff, Channel},
            FrameBin, State) ->
    SkipBits = (DOff * 4 - 8),
    <<Skip:SkipBits, FramePayload/binary>> = FrameBin,
    ?DEBUG("1.0 frame: ~p (skipped ~p)~n", [FramePayload, Skip]),
    handle_1_0_frame(Channel, FramePayload,
                     switch_callback(State, frame_header_1_0, 8));

%% The two rules pertaining to version negotiation:
%%
%% * If the server cannot support the protocol specified in the
%% protocol header, it MUST respond with a valid protocol header and
%% then close the socket connection.
%%
%% * The server MUST provide a protocol version that is lower than or
%% equal to that requested by the client in the protocol header.
handle_input(handshake, <<"AMQP", 0, 0, 9, 1>>, State) ->
    start_connection({0, 9, 1}, rabbit_framing_amqp_0_9_1, State);

%% This is the protocol header for 0-9, which we can safely treat as
%% though it were 0-9-1.
handle_input(handshake, <<"AMQP", 1, 1, 0, 9>>, State) ->
    start_connection({0, 9, 0}, rabbit_framing_amqp_0_9_1, State);

%% This is what most clients send for 0-8.  The 0-8 spec, confusingly,
%% defines the version as 8-0.
handle_input(handshake, <<"AMQP", 1, 1, 8, 0>>, State) ->
    start_connection({8, 0, 0}, rabbit_framing_amqp_0_8, State);

%% The 0-8 spec as on the AMQP web site actually has this as the
%% protocol header; some libraries e.g., py-amqplib, send it when they
%% want 0-8.
handle_input(handshake, <<"AMQP", 1, 1, 9, 1>>, State) ->
    start_connection({8, 0, 0}, rabbit_framing_amqp_0_8, State);

%% ... and finally, the 1.0 spec is crystal clear!  Note that the
%% Protocol supplied is vestigal; we use it as a marker, but not in
%% general where the 0-x code would use it as a module.
%% FIXME TLS and SASL use a different protocol number, and would go
%% here.
handle_input(handshake, <<"AMQP", 0, 1, 0, 0>>, State) ->
    start_1_0_connection({1, 0, 0}, rabbit_amqp1_0_framing, State);

handle_input(handshake, <<"AMQP", A, B, C, D>>, #v1{sock = Sock}) ->
    refuse_connection(Sock, {bad_version, A, B, C, D});

handle_input(handshake, Other, #v1{sock = Sock}) ->
    refuse_connection(Sock, {bad_header, Other});

handle_input(Callback, Data, _State) ->
    throw({bad_input, Callback, Data}).

%% Offer a protocol version to the client.  Connection.start only
%% includes a major and minor version number, Luckily 0-9 and 0-9-1
%% are similar enough that clients will be happy with either.
start_connection({ProtocolMajor, ProtocolMinor, _ProtocolRevision},
                 Protocol,
                 State = #v1{sock = Sock, connection = Connection}) ->
    Start = #'connection.start'{ version_major = ProtocolMajor,
                                 version_minor = ProtocolMinor,
                                 server_properties = server_properties(),
                                 mechanisms = <<"PLAIN AMQPLAIN">>,
                                 locales = <<"en_US">> },
    ok = send_on_channel0(Sock, Start, Protocol),
    switch_callback(State#v1{connection = Connection#connection{
                                            timeout_sec = ?NORMAL_TIMEOUT,
                                            protocol = Protocol},
                             connection_state = starting},
                    frame_header, 7).

start_1_0_connection({1, 0, 0},
                     Protocol,
                     State = #v1{sock = Sock, connection = Connection}) ->
    ok = inet_op(fun () -> rabbit_net:send(
                             Sock, <<"AMQP", 0, 1, 0, 0>>) end),
    switch_callback(State#v1{connection = Connection#connection{
                                            timeout_sec = ?NORMAL_TIMEOUT,
                                            protocol = Protocol},
                             connection_state = starting},
                    frame_header_1_0, 8).

refuse_connection(Sock, Exception) ->
    ok = inet_op(fun () -> rabbit_net:send(Sock, <<"AMQP",0,1,0,0>>) end),
    throw(Exception).

ensure_stats_timer(State = #v1{stats_timer = StatsTimer,
                               connection_state = running}) ->
    Self = self(),
    State#v1{stats_timer = rabbit_event:ensure_stats_timer(
                             StatsTimer,
                             fun() -> emit_stats(Self) end)};
ensure_stats_timer(State) ->
    State.

%%--------------------------------------------------------------------------

handle_method0(MethodName, FieldsBin,
               State = #v1{connection = #connection{protocol = Protocol}}) ->
    try
        handle_method0(Protocol:decode_method_fields(MethodName, FieldsBin),
                       State)
    catch exit:Reason ->
            CompleteReason = case Reason of
                                 #amqp_error{method = none} ->
                                     Reason#amqp_error{method = MethodName};
                                 OtherReason -> OtherReason
                             end,
            case ?IS_RUNNING(State) of
                true  -> send_exception(State, 0, CompleteReason);
                %% We don't trust the client at this point - force
                %% them to wait for a bit so they can't DOS us with
                %% repeated failed logins etc.
                false -> timer:sleep(?SILENT_CLOSE_DELAY * 1000),
                         throw({channel0_error, State#v1.connection_state,
                                CompleteReason})
            end
    end.

handle_method0(#'connection.start_ok'{mechanism = Mechanism,
                                      response = Response,
                                      client_properties = ClientProperties},
               State = #v1{connection_state = starting,
                           connection = Connection =
                               #connection{protocol = Protocol},
                           sock = Sock}) ->
    User = rabbit_access_control:check_login(Mechanism, Response),
    Tune = #'connection.tune'{channel_max = 0,
                              frame_max = ?FRAME_MAX,
                              heartbeat = 0},
    ok = send_on_channel0(Sock, Tune, Protocol),
    State#v1{connection_state = tuning,
             connection = Connection#connection{
                            user = User,
                            client_properties = ClientProperties}};
handle_method0(#'connection.tune_ok'{frame_max = FrameMax,
                                     heartbeat = ClientHeartbeat},
               State = #v1{connection_state = tuning,
                           connection = Connection,
                           sock = Sock,
                           start_heartbeat_fun = SHF}) ->
    if (FrameMax /= 0) and (FrameMax < ?FRAME_MIN_SIZE) ->
            rabbit_misc:protocol_error(
              not_allowed, "frame_max=~w < ~w min size",
              [FrameMax, ?FRAME_MIN_SIZE]);
       (?FRAME_MAX /= 0) and (FrameMax > ?FRAME_MAX) ->
            rabbit_misc:protocol_error(
              not_allowed, "frame_max=~w > ~w max size",
              [FrameMax, ?FRAME_MAX]);
       true ->
            SendFun =
                fun() ->
                        Frame = rabbit_binary_generator:build_heartbeat_frame(),
                        catch rabbit_net:send(Sock, Frame)
                end,

            Parent = self(),
            ReceiveFun =
                fun() ->
                        Parent ! timeout
                end,
            Heartbeater = SHF(Sock, ClientHeartbeat, SendFun,
                              ClientHeartbeat, ReceiveFun),
            State#v1{connection_state = opening,
                     connection = Connection#connection{
                                    timeout_sec = ClientHeartbeat,
                                    frame_max = FrameMax},
                     heartbeater = Heartbeater}
    end;

handle_method0(#'connection.open'{virtual_host = VHostPath},
               State = #v1{connection_state = opening,
                           connection = Connection = #connection{
                                          user = User,
                                          protocol = Protocol},
                           sock = Sock,
                           stats_timer = StatsTimer}) ->
    ok = rabbit_access_control:check_vhost_access(User, VHostPath),
    NewConnection = Connection#connection{vhost = VHostPath},
    ok = send_on_channel0(Sock, #'connection.open_ok'{}, Protocol),
    State1 = internal_conserve_memory(
               rabbit_alarm:register(self(), {?MODULE, conserve_memory, []}),
               State#v1{connection_state = running,
                        connection = NewConnection}),
    rabbit_event:notify(connection_created,
                        infos(?CREATION_EVENT_KEYS, State1)),
    rabbit_event:if_enabled(StatsTimer,
                            fun() -> internal_emit_stats(State1) end),
    State1;
handle_method0(#'connection.close'{}, State) when ?IS_RUNNING(State) ->
    lists:foreach(fun rabbit_framing_channel:shutdown/1, all_channels()),
    maybe_close(State#v1{connection_state = closing});
handle_method0(#'connection.close'{},
               State = #v1{connection_state = CS,
                           connection = #connection{protocol = Protocol},
                           sock = Sock})
  when CS =:= closing; CS =:= closed ->
    %% We're already closed or closing, so we don't need to cleanup
    %% anything.
    ok = send_on_channel0(Sock, #'connection.close_ok'{}, Protocol),
    State;
handle_method0(#'connection.close_ok'{},
               State = #v1{connection_state = closed}) ->
    self() ! terminate_connection,
    State;
handle_method0(_Method, State = #v1{connection_state = CS})
  when CS =:= closing; CS =:= closed ->
    State;
handle_method0(_Method, #v1{connection_state = S}) ->
    rabbit_misc:protocol_error(
      channel_error, "unexpected method in connection state ~w", [S]).

send_on_channel0(Sock, Method, Protocol) ->
    ok = rabbit_amqp1_0_writer:internal_send_command(Sock, 0, Method, Protocol).

%%--------------------------------------------------------------------------

infos(Items, State) -> [{Item, i(Item, State)} || Item <- Items].

i(pid, #v1{}) ->
    self();
i(address, #v1{sock = Sock}) ->
    socket_info(fun rabbit_net:sockname/1, fun ({A, _}) -> A end, Sock);
i(port, #v1{sock = Sock}) ->
    socket_info(fun rabbit_net:sockname/1, fun ({_, P}) -> P end, Sock);
i(peer_address, #v1{sock = Sock}) ->
    socket_info(fun rabbit_net:peername/1, fun ({A, _}) -> A end, Sock);
i(peer_port, #v1{sock = Sock}) ->
    socket_info(fun rabbit_net:peername/1, fun ({_, P}) -> P end, Sock);
i(ssl, #v1{sock = Sock}) ->
    rabbit_net:is_ssl(Sock);
i(peer_cert_issuer, #v1{sock = Sock}) ->
    cert_info(fun rabbit_ssl:peer_cert_issuer/1, Sock);
i(peer_cert_subject, #v1{sock = Sock}) ->
    cert_info(fun rabbit_ssl:peer_cert_subject/1, Sock);
i(peer_cert_validity, #v1{sock = Sock}) ->
    cert_info(fun rabbit_ssl:peer_cert_validity/1, Sock);
i(SockStat, #v1{sock = Sock}) when SockStat =:= recv_oct;
                                   SockStat =:= recv_cnt;
                                   SockStat =:= send_oct;
                                   SockStat =:= send_cnt;
                                   SockStat =:= send_pend ->
    socket_info(fun () -> rabbit_net:getstat(Sock, [SockStat]) end,
                fun ([{_, I}]) -> I end);
i(state, #v1{connection_state = S}) ->
    S;
i(channels, #v1{}) ->
    length(all_channels());
i(protocol, #v1{connection = #connection{protocol = none}}) ->
    none;
i(protocol, #v1{connection = #connection{protocol = Protocol}}) ->
    Protocol:version();
i(user, #v1{connection = #connection{user = #user{username = Username}}}) ->
    Username;
i(user, #v1{connection = #connection{user = none}}) ->
    '';
i(vhost, #v1{connection = #connection{vhost = VHost}}) ->
    VHost;
i(timeout, #v1{connection = #connection{timeout_sec = Timeout}}) ->
    Timeout;
i(frame_max, #v1{connection = #connection{frame_max = FrameMax}}) ->
    FrameMax;
i(client_properties, #v1{connection = #connection{
                           client_properties = ClientProperties}}) ->
    ClientProperties;
i(Item, #v1{}) ->
    throw({bad_argument, Item}).

socket_info(Get, Select, Sock) ->
    socket_info(fun() -> Get(Sock) end, Select).

socket_info(Get, Select) ->
    case Get() of
        {ok,    T} -> Select(T);
        {error, _} -> ''
    end.

cert_info(F, Sock) ->
    case rabbit_net:peercert(Sock) of
        nossl                -> '';
        {error, no_peercert} -> '';
        {ok, Cert}           -> list_to_binary(F(Cert))
    end.

%%--------------------------------------------------------------------------

send_to_new_channel(Channel, AnalyzedFrame, State) ->
    #v1{sock = Sock, queue_collector = Collector,
        channel_sup_sup_pid = ChanSupSup,
        connection = #connection{protocol  = Protocol,
                                 frame_max = FrameMax,
                                 user      = #user{username = Username},
                                 vhost     = VHost}} = State,
    {ok, ChSupPid, ChFrPid} =
        rabbit_channel_sup_sup:start_channel(
          ChanSupSup, {Protocol, Sock, Channel, FrameMax,
                       self(), Username, VHost, Collector}),
    erlang:monitor(process, ChSupPid),
    put({channel, Channel}, {ch_fr_pid, ChFrPid}),
    put({ch_sup_pid, ChSupPid}, {{channel, Channel}, {ch_fr_pid, ChFrPid}}),
    put({ch_fr_pid, ChFrPid}, {channel, Channel}),
    ok = rabbit_framing_channel:process(ChFrPid, AnalyzedFrame).

send_to_new_1_0_session(Channel, Frame, State) ->
    #v1{sock = Sock, queue_collector = Collector,
        channel_sup_sup_pid = ChanSupSup,
        connection = #connection{protocol  = Protocol,
                                 frame_max = FrameMax,
                                 %% FIXME SASL, TLS, etc.
                                 user      = User,
                                 vhost     = VHost}} = State,
    {ok, ChSupPid, ChFrPid} =
        %% Note: the equivalent, start_channel is in channel_sup_sup
        rabbit_amqp1_0_session_sup_sup:start_session(
          ChanSupSup, {Protocol, Sock, Channel, FrameMax,
                       self(), User, VHost, Collector}),
    erlang:monitor(process, ChSupPid),
    put({channel, Channel}, {ch_fr_pid, ChFrPid}),
    put({ch_sup_pid, ChSupPid}, {{channel, Channel}, {ch_fr_pid, ChFrPid}}),
    put({ch_fr_pid, ChFrPid}, {channel, Channel}),
    ok = rabbit_amqp1_0_session:process_frame(ChFrPid, Frame).

log_channel_error(ConnectionState, Channel, Reason) ->
    rabbit_log:error("connection ~p (~p), channel ~p - error:~n~p~n",
                     [self(), ConnectionState, Channel, Reason]).

handle_exception(State = #v1{connection_state = closed}, Channel, Reason) ->
    log_channel_error(closed, Channel, Reason),
    State;
handle_exception(State = #v1{connection_state = CS}, Channel, Reason) ->
    log_channel_error(CS, Channel, Reason),
    send_exception(State, Channel, Reason).

send_exception(State = #v1{connection = #connection{protocol = Protocol}},
               Channel, Reason) ->
    {ShouldClose, CloseChannel, CloseMethod} =
        rabbit_binary_generator:map_exception(Channel, Reason, Protocol),
    NewState = case ShouldClose of
                   true  -> terminate_channels(),
                            close_connection(State);
                   false -> close_channel(Channel, State)
               end,
    ok = rabbit_writer:internal_send_command(
           NewState#v1.sock, CloseChannel, CloseMethod, Protocol),
    NewState.

internal_emit_stats(State = #v1{stats_timer = StatsTimer}) ->
    rabbit_event:notify(connection_stats, infos(?STATISTICS_KEYS, State)),
    State#v1{stats_timer = rabbit_event:reset_stats_timer(StatsTimer)}.