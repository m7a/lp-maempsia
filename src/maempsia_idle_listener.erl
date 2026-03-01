-module(maempsia_idle_listener).
-behavior(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
-include_lib("kernel/include/logger.hrl").

% This gen_server listens for idle events and upon receiving an update sends
% out augmented {mpd_idle, PropList} messages to InterestedReceivers. It then
% proceeds to listen for further idle() events. This is derived from
% maenmpc_mpd.erl and intended to distribute the information about idle events
% to multiple potential receivers (e.g. scrobbler, radio, podcast)
%   The implementation casts to self to keep the endless idle_receive() loop
% going. This was deemed easier to implement than a “stateless statemachine”
% (gen_statem) which would have been a viable alternative, too:
% https://stackoverflow.com/questions/6052954/is-it-bad-to-send-a-message-to-

init([MPD, InterestedReceivers]) ->
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	ok = erlmpd:idle_send(Conn, [playlist, player]),
	ok = gen_server:cast(self(), mpd_idle),
	{ok, {Conn, InterestedReceivers}}.

handle_call(_Other, _From, State) ->
	{reply, ok, State}.

handle_cast(mpd_idle, State={Conn, InterestedReceivers}) ->
	?LOG_DEBUG("idle receive..."),
	IdleResult = erlmpd:idle_receive(Conn),
	MessageProps = [{idle_result, IdleResult}|
					maempsia_erlmpd:get_status_props(Conn)],
	ok = erlmpd:idle_send(Conn, [playlist, player]),
	?LOG_DEBUG("idle message to <~w>", [InterestedReceivers]),
	lists:foreach(fun(Target) ->
			ok = gen_server:cast(Target, {mpd_idle, MessageProps}) 
		end, InterestedReceivers),
	ok = gen_server:cast(self(), mpd_idle),
	{noreply, State}.

handle_info(_Message,    State)         -> {noreply, State}.
code_change(_OldVersion, State, _Extra) -> {ok,      State}.
