-module(rabbit_amqp1_0_session_process).

-behaviour(gen_server2).

-export([init/1, terminate/2, code_change/3,
         handle_call/3, handle_cast/2, handle_info/2]).

-export([start_link/7]).

-ifdef(debug).
-export([parse_destination/1]).
-endif.

%% TODO monitor declaring channel since we now don't reopen it if an error
%% occurs (or with_sacrificial_channel() ala federation)

-record(state, {backing_connection, backing_channel,
                declaring_channel, %% a sacrificial client channel for declaring things
                reader_pid, writer_pid, session}).

%% TODO test where the sweetspot for gb_trees is
-define(MAX_SESSION_BUFFER_SIZE, 4096).
-define(DEFAULT_MAX_HANDLE, 16#ffffffff).

-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_amqp1_0.hrl").
-include("rabbit_amqp1_0_session.hrl").

-import(rabbit_amqp1_0_link_util, [protocol_error/3]).

%% TODO account for all these things
start_link(Channel, ReaderPid, WriterPid, User, VHost,
           _Collector, _StartLimiterFun) ->
    gen_server2:start_link(
      ?MODULE, [Channel, ReaderPid, WriterPid, User, VHost], []).

%% ---------

init([Channel, ReaderPid, WriterPid, #user{username = Username}, VHost]) ->
    {ok, Conn} = amqp_connection:start(
                   %% TODO #adapter_info{}
                   #amqp_params_direct{username     = Username,
                                       virtual_host = <<"/">>}),
    {ok, Ch} = amqp_connection:open_channel(Conn),
    {ok, Ch2} = amqp_connection:open_channel(Conn),
    {ok, #state{backing_connection     = Conn,
                backing_channel        = Ch,
                declaring_channel      = Ch2,
                reader_pid             = ReaderPid,
                writer_pid             = WriterPid,
                session = #session{ channel_num            = Channel,
                                    next_publish_id        = 0,
                                    ack_counter            = 0,
                                    incoming_unsettled_map = gb_trees:empty(),
                                    outgoing_unsettled_map = gb_trees:empty()}
               }}.

terminate(_Reason, _State = #state{ backing_connection = Conn,
                                      declaring_channel  = DeclCh,
                                      backing_channel    = Ch}) ->
    ?DEBUG("Shutting down session ~p", [_State]),
    case DeclCh of
        undefined -> ok;
        Channel   -> amqp_channel:close(Channel)
    end,
    amqp_channel:close(Ch),
    %% TODO: closing the connection here leads to errors in the logs
    amqp_connection:close(Conn),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call(Msg, _From, State) ->
    {reply, {error, not_understood, Msg}, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    %% Handled above
    {noreply, State};

handle_info({#'basic.deliver'{} = Deliver, Msg},
            State = #state{writer_pid      = WriterPid,
                           backing_channel = BCh,
                           session         = Session}) ->
    {ok, Session1} = rabbit_amqp1_0_outgoing_link:deliver(
                       Deliver, Msg, WriterPid, BCh, Session),
    {noreply, State#state{session = Session1}};

%% A message from the queue saying that the credit is either exhausted
%% or there are no more messages
handle_info(#'basic.credit_state'{} = CreditState,
            State = #state{writer_pid = WriterPid}) ->
    rabbit_amqp1_0_outgoing_link:update_credit(CreditState, WriterPid),
    {noreply, State};

%% An acknowledgement from the queue.  To keep the incoming window
%% moving, we make sure to update them with the session counters every
%% once in a while.  Assuming that the buffer is an appropriate size,
%% about once every window_size / 2 is a good heuristic.
handle_info(#'basic.ack'{delivery_tag = DTag, multiple = Multiple},
            State = #state{writer_pid = WriterPid,
                           session = Session = #session{
                                       incoming_unsettled_map = Unsettled,
                                       window_size = Window,
                                       ack_counter = AckCounter}}) ->
    {TransferIds, Unsettled1} =
        case Multiple of
            true  -> acknowledgement_range(DTag, Unsettled);
            false -> case gb_trees:lookup(DTag, Unsettled) of
                         {value, Id} ->
                             {[Id], gb_trees:delete(DTag, Unsettled)};
                         none ->
                             {[], Unsettled}
                     end
        end,
    case TransferIds of
        [] -> ok;
        _  -> D = acknowledgement(TransferIds,
                                  #'v1_0.disposition'{role = ?RECV_ROLE}),
              rabbit_amqp1_0_writer:send_command(WriterPid, D)
    end,
    HalfWindow = Window div 2,
    AckCounter1 = case (AckCounter + length(TransferIds)) of
                      Over when Over >= HalfWindow ->
                          F = rabbit_amqp1_0_session:flow_fields(
                                State#state.session),
                          rabbit_amqp1_0_writer:send_command(WriterPid, F),
                          Over - HalfWindow;
                      Counter ->
                          Counter
                  end,
    {noreply, State#state{session = Session#session{
                                      ack_counter = AckCounter1,
                                      incoming_unsettled_map = Unsettled1}}};

%% TODO these pretty much copied wholesale from rabbit_channel
handle_info({'EXIT', WriterPid, Reason = {writer, send_failed, _Error}},
            State = #state{writer_pid = WriterPid}) ->
    State#state.reader_pid ! {channel_exit, State#state.session#session.channel_num, Reason},
    {stop, normal, State};
handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};
handle_info({'DOWN', _MRef, process, _QPid, _Reason}, State) ->
    %% TODO do we care any more since we're using direct client?
    {noreply, State}. % FIXME rabbit_channel uses queue_blocked?

handle_cast({frame, Frame},
            State = #state{ writer_pid = Sock }) ->
    try handle_control(Frame, State) of
        {reply, Replies, NewState} when is_list(Replies) ->
            lists:foreach(fun (Reply) ->
                                  rabbit_amqp1_0_writer:send_command(Sock, Reply)
                          end, Replies),
            noreply(NewState);
        {reply, Reply, NewState} ->
            rabbit_amqp1_0_writer:send_command(Sock, Reply),
            noreply(NewState);
        {noreply, NewState} ->
            noreply(NewState);
        stop ->
            {stop, normal, State}
    catch exit:Reason = #'v1_0.error'{} ->
            %% TODO shut down nicely like rabbit_channel
            Close = #'v1_0.end'{ error = Reason },
            ok = rabbit_amqp1_0_writer:send_command(Sock, Close),
            {stop, normal, State};
          exit:normal ->
            {stop, normal, State};
          _:Reason ->
            {stop, {Reason, erlang:get_stacktrace()}, State}
    end.

%% TODO rabbit_channel returns {noreply, State, hibernate}, but that
%% appears to break things here (it stops the session responding to
%% frames).
noreply(State) ->
    {noreply, State}.

%% ------

%% Session window:
%%
%% Each session has two buffers, one to record the unsettled state of
%% incoming messages, one to record the unsettled state of outgoing
%% messages.  In general we want to bound these buffers; but if we
%% bound them, and don't tell the other side, we may end up
%% deadlocking the other party.
%%
%% Hence the flow frame contains a session window, expressed as the
%% next-id and the window size for each of the buffers. The frame
%% refers to the buffers of the sender of the frame, of course.
%%
%% The numbers work this way: for the outgoing buffer, the next-id is
%% the next transfer id the session will send, and it will stop
%% sending at next-id + window.  For the incoming buffer, the next-id
%% is the next transfer id expected, and it will not accept messages
%% beyond next-id + window (in fact it will probably close the
%% session, since sending outside the window is a transgression of the
%% protocol).
%%
%% Usually we will want to base our incoming window size on the other
%% party's outgoing window size (given in begin{}), since we will
%% never need more state than they are keeping (they'll stop sending
%% before that happens), subject to a maximum.  Similarly the outgoing
%% window, on the basis that the other party is likely to make its
%% buffers the same size (or that's our best guess).
%%
%% Note that we will occasionally overestimate these buffers, because
%% the far side may be using a circular buffer, in which case they
%% care about the distance from the low water mark (i.e., the least
%% transfer for which they have unsettled state) rather than the
%% number of entries.
%%
%% We use ordered sets for our buffers, which means we care about the
%% total number of entries, rather than the smallest entry. Thus, our
%% window will always be, by definition, BOUND - TOTAL.

handle_control(#'v1_0.begin'{next_outgoing_id = {uint, RemoteNextIn},
                             incoming_window = RemoteInWindow,
                             outgoing_window = RemoteOutWindow,
                             handle_max = HandleMax0},
               State = #state{
                 backing_channel = AmqpChannel,
                 session = Session = #session{
                             next_transfer_number = LocalNextOut,
                             channel_num = Channel}}) ->
    Window =
        case RemoteInWindow of
            {uint, Size} -> Size;
            undefined    -> ?MAX_SESSION_BUFFER_SIZE
        end,
    HandleMax = case HandleMax0 of
                    {uint, Max} -> Max;
                    _ -> ?DEFAULT_MAX_HANDLE
                end,
    %% TODO does it make sense to have two different sizes
    SessionBufferSize = erlang:min(Window, ?MAX_SESSION_BUFFER_SIZE),
    %% Attempt to limit the number of "at risk" messages we can have.
    amqp_channel:cast(AmqpChannel,
                      #'basic.qos'{prefetch_count = SessionBufferSize}),
    {reply, #'v1_0.begin'{
       remote_channel = {ushort, Channel},
       handle_max = {uint, HandleMax},
       next_outgoing_id = {uint, LocalNextOut},
       incoming_window = {uint, SessionBufferSize},
       outgoing_window = {uint, SessionBufferSize}},
     State#state{
       session = Session#session{
                   next_incoming_id = RemoteNextIn,
                   max_outgoing_id = rabbit_misc:serial_add(RemoteNextIn, Window),
                   window_size = SessionBufferSize}}};

handle_control(#'v1_0.attach'{role = ?SEND_ROLE} = Attach,
               State = #state{backing_channel   = BCh,
                              declaring_channel = DCh,
                              session           = Session}) ->
    {ok, Reply, Confirm} =
        rabbit_amqp1_0_incoming_link:attach(Attach, BCh, DCh),
    reply(Reply,
          State#state{session = rabbit_amqp1_0_session:maybe_init_publish_id(
                                  Confirm, Session)});

handle_control(#'v1_0.attach'{role                   = ?RECV_ROLE,
                              initial_delivery_count = undefined} = Attach,
               State = #state{backing_channel   = BCh,
                              declaring_channel = DCh}) ->
    {ok, Reply} = rabbit_amqp1_0_outgoing_link:attach(Attach, BCh, DCh),
    reply(Reply, State);

handle_control([Txfr = #'v1_0.transfer'{settled = Settled,
                                        delivery_id = {uint, TxfrId}} | Msg],
               State = #state{backing_channel = BCh,
                              session         = Session}) ->
    {ok, Reply} = rabbit_amqp1_0_incoming_link:transfer(Txfr, Msg, BCh),
    reply(Reply, State#state{session = rabbit_amqp1_0_session:record_publish(
                                         Settled, TxfrId, Session)});

%% Disposition: a single extent is settled at a time.  This may
%% involve more than one message. TODO: should we send a flow after
%% this, to indicate the state of the session window?
handle_control(#'v1_0.disposition'{ role = ?RECV_ROLE } = Disp, State) ->
    case settle(Disp, State) of
        {none, NewState} ->
            {noreply, NewState};
        {ReplyDisp, NewState} ->
            {reply, ReplyDisp, NewState}
    end;

handle_control(#'v1_0.detach'{ handle = Handle }, State) ->
    %% TODO keep the state around depending on the lifetime
    erase({in, Handle}),
    {reply, #'v1_0.detach'{ handle = Handle }, State};

handle_control(#'v1_0.end'{}, _State = #state{ writer_pid = Sock }) ->
    ok = rabbit_amqp1_0_writer:send_command(Sock, #'v1_0.end'{}),
    stop;

%% Flow control.  These frames come with two pieces of information:
%% the session window, and optionally, credit for a particular link.
%% We'll deal with each of them separately.
%%
%% See above regarding the session window. We should already know the
%% next outgoing transfer sequence number, because it's one more than
%% the last transfer we saw; and, we don't need to know the next
%% incoming transfer sequence number (although we might use it to
%% detect congestion -- e.g., if it's lagging far behind our outgoing
%% sequence number). We probably care about the outgoing window, since
%% we want to keep it open by sending back settlements, but there's
%% not much we can do to hurry things along.
%%
%% We do care about the incoming window, because we must not send
%% beyond it. This may cause us problems, even in normal operation,
%% since we want our unsettled transfers to be exactly those that are
%% held as unacked by the backing channel; however, the far side may
%% close the window while we still have messages pending
%% transfer. Note that this isn't a race so far as AMQP 1.0 is
%% concerned; it's only because AMQP 0-9-1 defines QoS in terms of the
%% total number of unacked messages, whereas 1.0 has an explicit window.
handle_control(Flow = #'v1_0.flow'{},
               State = #state{backing_channel = BCh,
                              session = Session = #session{
                                          next_incoming_id = LocalNextIn,
                                          max_outgoing_id = _LocalMaxOut,
                                          next_transfer_number = LocalNextOut}}) ->
    #'v1_0.flow'{ next_incoming_id = RemoteNextIn0,
                  incoming_window = {uint, RemoteWindowIn},
                  next_outgoing_id = {uint, RemoteNextOut},
                  outgoing_window = {uint, RemoteWindowOut}} = Flow,
    %% Check the things that we know for sure
    %% TODO sequence number comparisons
    ?DEBUG("~p == ~p~n", [RemoteNextOut, LocalNextIn]),
    %% TODO the Python client sets next_outgoing_id=2 on begin, then sends a
    %% flow with next_outgoing_id=1. Not sure what that's meant to mean.
    %% RemoteNextOut = LocalNextIn,
    %% The far side may not have our begin{} with our next-transfer-id
    RemoteNextIn = case RemoteNextIn0 of
                       {uint, Id} -> Id;
                       undefined  -> LocalNextOut
                   end,
    ?DEBUG("~p =< ~p~n", [RemoteNextIn, LocalNextOut]),
    true = (RemoteNextIn =< LocalNextOut),
    %% Adjust our window
    RemoteMaxOut = RemoteNextIn + RemoteWindowIn,
    State1 = State#state{session = Session#session{
                                     max_outgoing_id = RemoteMaxOut}},
    case Flow#'v1_0.flow'.handle of
        undefined ->
            {noreply, State1};
        Handle ->
            case get({in, Handle}) of
                undefined ->
                    case get({out, Handle}) of
                        undefined ->
                            rabbit_log:warning("Flow for unknown link handle ~p", [Flow]),
                            protocol_error(?V_1_0_AMQP_ERROR_INVALID_FIELD,
                                           "Unattached handle: ~p", [Handle]);
                        Out ->
                            {ok, Reply} = rabbit_amqp1_0_outgoing_link:flow(
                                            Out, Flow, BCh),
                            reply(Reply, State1)
                    end;
                _In ->
                    %% We're being told about available messages at
                    %% the sender.  Yawn.
                    %% TODO at least check transfer-count?
                    {noreply, State1}
            end
    end;

handle_control(Frame, State) ->
    %% FIXME should this bork?
    io:format("Ignoring frame: ~p~n", [Frame]),
    {noreply, State}.

%% ------

reply([], State) ->
    {noreply, State};
reply(Reply, State = #state{session = Session}) ->
    {reply, rabbit_amqp1_0_session:flow_fields(Reply, Session), State}.

%% We've been told that the fate of a transfer has been determined.
%% Generally if the other side has not settled it, we will do so.  If
%% the other side /has/ settled it, we don't need to reply -- it's
%% already forgotten its state for the transfer anyway.
settle(Disp = #'v1_0.disposition'{ first = First0,
                                   last = Last0,
                                   settled = Settled,
                                   state = Outcome },
       State = #state{backing_channel = Ch,
                      session = Session = #session{
                                  outgoing_unsettled_map = Unsettled}}) ->
    {uint, First} = First0,
    %% Last may be omitted, in which case it's the same as first
    Last = case Last0 of
               {uint, L} -> L;
               undefined -> First
           end,

    %% The other party may be talking about something we've already
    %% forgotten; this isn't a crime, we can just ignore it.

    case gb_trees:is_empty(Unsettled) of
        true ->
            {none, State};
        false ->
            {LWM, _} = gb_trees:smallest(Unsettled),
            {HWM, _} = gb_trees:largest(Unsettled),
            if Last < LWM ->
                    {none, State};
               First > HWM ->
                    State; %% FIXME this should probably be an error, rather than ignored.
               true ->
                    Unsettled1 =
                        lists:foldl(
                          fun (Transfer, Map) ->
                                  case gb_trees:lookup(Transfer, Map) of
                                      none ->
                                          Map;
                                      {value, Entry} ->
                                          ?DEBUG("Settling ~p with ~p~n", [Transfer, Outcome]),
                                          #outgoing_transfer{ delivery_tag = DeliveryTag } = Entry,
                                          Ack =
                                              case Outcome of
                                                  #'v1_0.accepted'{} ->
                                                      #'basic.ack' {delivery_tag = DeliveryTag,
                                                                    multiple     = false };
                                                  #'v1_0.rejected'{} ->
                                                      #'basic.reject' {delivery_tag = DeliveryTag,
                                                                       requeue      = false };
                                                  #'v1_0.released'{} ->
                                                      #'basic.reject' {delivery_tag = DeliveryTag,
                                                                       requeue      = true }
                                              end,
                                          ok = amqp_channel:call(Ch, Ack),
                                          gb_trees:delete(Transfer, Map)
                                  end
                          end,
                          Unsettled, lists:seq(erlang:max(LWM, First),
                                               erlang:min(HWM, Last))),
                    {case Settled of
                         true  -> none;
                         false -> Disp#'v1_0.disposition'{ settled = true,
                                                           role = ?SEND_ROLE }
                     end,
                     State#state{session = Session#session{outgoing_unsettled_map = Unsettled1}}}
            end
    end.

acknowledgement_range(DTag, Unsettled) ->
    acknowledgement_range(DTag, Unsettled, []).

acknowledgement_range(DTag, Unsettled, Acc) ->
    case gb_trees:is_empty(Unsettled) of
        true ->
            {lists:reverse(Acc), Unsettled};
        false ->
            {DTag1, TransferId} = gb_trees:smallest(Unsettled),
            case DTag1 =< DTag of
                true ->
                    {_K, _V, Unsettled1} = gb_trees:take_smallest(Unsettled),
                    acknowledgement_range(DTag, Unsettled1,
                                          [TransferId|Acc]);
                false ->
                    {lists:reverse(Acc), Unsettled}
            end
    end.

acknowledgement(TransferIds, Disposition) ->
    Disposition#'v1_0.disposition'{ first = {uint, hd(TransferIds)},
                                    last = {uint, lists:last(TransferIds)},
                                    settled = true,
                                    state = #'v1_0.accepted'{} }.
