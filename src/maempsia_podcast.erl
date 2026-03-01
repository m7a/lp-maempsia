-module(maempsia_podcast).
-behavior(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
-include_lib("kernel/include/logger.hrl").

% implementation mostly copied from maenmpc_podcast.erl
-record(rp, {mpd, config, is_active, is_playing, filelist}).

init([Options]) ->
	{ok, ConfPodcast} = application:get_env(maempsia, podcast),
	{ok, _TRef} = timer:send_interval(maps:get(interval, ConfPodcast),
							interrupt_check),
	{ok, #rp{
		mpd        = proplists:get_value(mpd, Options),
		config     = ConfPodcast,
		is_playing = false,
		is_active  = false,
		filelist   = []
	}}.

handle_call(is_active, _From, Ctx = #rp{is_active = Active}) ->
	{reply, Active, Ctx};
handle_call(_Call, _From, Ctx) ->
	{ok, Ctx}.

handle_cast(podcast_start, Ctx = #rp{is_active=false}) ->
	?LOG_INFO("podcast_start"),
	Ctx2 = podcast_run_inner(Ctx#rp{is_active = true}),
	?LOG_INFO("podcast_start completed"),
	{noreply, Ctx2};
handle_cast(podcast_stop, Ctx) ->
	{noreply, Ctx#rp{is_active = false}};
handle_cast({mpd_idle, Prop}, Ctx) ->
	{noreply, Ctx#rp{is_playing = (proplists:get_value(state,
		proplists:get_value(status, Prop, []), not_playing) =:= play)}};
handle_cast(_Other, Ctx) ->
	{noreply, Ctx}.

podcast_run_inner(Ctx = #rp{config=Conf}) ->
	case subprocess_run_await(["podget", "-d", maps:get(conf, Conf)],
					maps:get(timeout, Conf), error) of
	{ok, _Cnt} ->
		Ctx#rp{filelist =
			lists:sort(filelib:wildcard(maps:get(glob, Conf)))};
	{timeout, Lines} ->
		?LOG_WARNING("podcast_run_inner timeout: ~p", [Lines]),
		Ctx;
	{error, Token, Error} ->
		?LOG_ERROR("podcast_run_inner: T=~p E=~p", [Token, Error]),
		Ctx
	end.

subprocess_run_await([ExecutableName|Args], Timeout, TimeoutAction) ->
	Port = open_port({spawn_executable, os:find_executable(ExecutableName)},
			[{args, Args}, stream, exit_status,
					use_stdio, stderr_to_stdout, in]),
	{ok, Timer} = timer:send_after(Timeout, {Port,
						{timeout, TimeoutAction}}),
	subprocess_get_data(Timer, Port, []).

subprocess_get_data(Timer, Port, Acc) ->
	receive
	{Port, {timeout, detach}} ->
		{timeout, lists:reverse(Acc)};
	{Port, {timeout, error}} ->
		port_close(Port),
		{error, timeout, lists:reverse(Acc)};
	{Port, {data, D}} ->
		subprocess_get_data(Timer, Port, [D|Acc]);
	{Port, {exit_status, RC}} ->
		% Race Condition: If the timer fires just after the exit status
		% but before we can cancel it here, then the message
		% {timeout, ...} is going to be ignored and processed upon
		% the next subprocess interaction (see subprocess_run_await)
		timer:cancel(Timer),
		case RC == 0 of
		true  -> {ok, lists:reverse(Acc)};
		false -> {error, RC, lists:reverse(Acc)}
		end;
	% Since we can have detached processes it may be the case that some
	% other process is still sending us messages. e.g. if its timer was
	% not cancelled correctly due to race condition or if the program was
	% detached to background and is now printing stuff to console or
	% exiting. This block catches all of these instances and drops their
	% data.
	{_Other, {timeout, _Setting}} ->
		subprocess_get_data(Timer, Port, Acc);
	{_Other, {data, _Data}} ->
		subprocess_get_data(Timer, Port, Acc);
	{_Other, {exit_status, _RC}} ->
		subprocess_get_data(Timer, Port, Acc)
	end.

handle_info(interrupt_check, Ctx = #rp{is_active=true}) ->
	?LOG_INFO("podcast interrupt_check"),
	{noreply, podcast_process(Ctx)};
handle_info(_Message, Ctx) ->
	{noreply, Ctx}.

podcast_process(Ctx = #rp{filelist=OldState, is_playing=IsPlaying}) ->
	Ctx2 = podcast_run_inner(Ctx),
	NewState = Ctx2#rp.filelist,
	NewFiles = NewState -- OldState,
	case (NewFiles =/= []) and IsPlaying of
	true  -> play(lists:last(NewFiles), Ctx2);
	false -> Ctx2
	end.

play(File, Ctx = #rp{mpd=MPD, config=Config}) ->
	?LOG_INFO("podcast process new episode ~s", [File]),
	TargetFS = maps:get(target_fs, Config),
	% copy_then_run, copy, move
	case lists:suffix(".flac", TargetFS) of
	true ->
		TempFN = tmpnam(".flac"),
		copy_then_run(Ctx, File, TempFN, TargetFS,
				["loudgain", "-r", "-k", "-s", "e", TempFN]);
	false ->
		case lists:suffix(".mp3", TargetFS) of
		true ->
			TempFN = tmpnam(".mp3"),
			copy_then_run(Ctx, File, TempFN, TargetFS,
					["loudgain", "-I3", "-S", "-L", "-r",
					"-k", "-s", "e", TempFN]);
		false ->
			?LOG_WARNING("podcast no loudgain on unknown type: ~s",
								[TargetFS]),
			{ok, _Bytes} = file:copy(File, TargetFS)
		end
	end,
	TargetMPD = maps:get(target_mpd, Config),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	case erlmpd:addid_relative(Conn, TargetMPD, 0) of
	{error, Err} -> ?LOG_ERROR("podcast enqueue error ~p", [Err]);
	_Other       -> ok
	end,
	erlmpd:disconnect(Conn),
	Ctx.

% https://erlang.org/pipermail/erlang-questions/2009-September/046694.html
% https://stackoverflow.com/questions/1222084/how-do-i-create-a-temp-filename-
tmpnam(Suffix) ->
	filename:join(os:getenv("TMP", "/tmp"), io_lib:format("podcast_~w~s",
					[erlang:unique_integer(), Suffix])).

copy_then_run(Ctx = #rp{config=Config}, File, TempFN, TargetFS, CMD) ->
	TargetFS = maps:get(target_fs, Config),
	{ok, _Bytes} = file:copy(File, TempFN),
	ok = run_process_require_success(CMD, Ctx),
	{ok, _Bytes2} = file:copy(TempFN, TargetFS),
	ok = file:delete(TempFN).

run_process_require_success(Cmd, #rp{config=Config}) ->
	?LOG_INFO("podcast run command ~p", [Cmd]),
	case subprocess_run_await(Cmd, maps:get(timeout, Config), error) of
	{ok, _Output} ->
		ok;
	Other ->
		?LOG_ERROR("podcast external command failed: ~p", [Other]),
		error
	end.

code_change(_OldVersion, Ctx, _Extra) -> {ok, Ctx}.
