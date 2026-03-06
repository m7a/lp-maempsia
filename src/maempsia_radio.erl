-module(maempsia_radio).
-behavior(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).
-include_lib("kernel/include/logger.hrl").

-record(rr, {mpd, conf_radio, conf_playlist_gen, generator_type, schedule}).

init([Options]) ->
	{ok, ConfRadio}           = application:get_env(maempsia, radio),
	{ok, ConfPlayListGen}     = application:get_env(maempsia, playlist_gen),
	DefaultCtx = #rr{
		mpd               = proplists:get_value(mpd, Options),
		conf_radio        = ConfRadio,
		conf_playlist_gen = ConfPlayListGen,
		generator_type    = maempsia_pl_radio,
		schedule          = []
	},
	{ok, case proplists:get_value(radio, Options) of
	undefined   -> DefaultCtx;
	[[]]        -> radio_start(DefaultCtx, DefaultCtx#rr.generator_type);
	[Generator] -> radio_start(DefaultCtx, list_to_atom(Generator))
	end}.

handle_call(get_schedule, _From,
			Ctx = #rr{generator_type=Type, schedule=Sched}) ->
	{reply, {Type, Sched}, Ctx};
handle_call(_Call, _From, Ctx) ->
	{reply, ok, Ctx}.

handle_cast({radio_start, GeneratorType}, Ctx) ->
	{noreply, radio_start(Ctx, GeneratorType)};
handle_cast(radio_stop, Ctx) ->
	{noreply, radio_stop(Ctx)};
handle_cast({mpd_idle, Prop}, Ctx) ->
	{noreply, radio_check_song(Ctx, proplists:get_value(file,
				proplists:get_value(currentsong, Prop, [])))};
handle_cast(_Other, Ctx) ->
	{noreply, Ctx}.

radio_start(Ctx, NewGen) when (Ctx#rr.generator_type == NewGen) and
						(Ctx#rr.schedule =/= []) -> Ctx;
radio_start(Ctx, NewGen) ->
	?LOG_INFO("start radio, generate with ~w", [NewGen]),
	Ctx2 = Ctx#rr{generator_type = NewGen},
	radio_enqueue(Ctx2#rr{schedule = schedule_compute(Ctx2)}).

% dequeue on recognize
radio_enqueue(Ctx = #rr{mpd=MPD, schedule=[URI|T]}) ->
	?LOG_DEBUG("radio enqueue <~s>", [URI]),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	ok = erlmpd:add(Conn, URI),
	erlmpd:disconnect(Conn),
	case T of
	% ensure that next time we recognize to input the next song!
	[]    -> Ctx#rr{schedule = [URI|schedule_compute(Ctx)]};
	_More -> Ctx
	end.

% returns the raw schedule ready for editing into the context
schedule_compute(#rr{mpd=MPD, conf_radio=Radio, conf_playlist_gen=PLG,
							generator_type=Gen}) ->
	Gen:generate(MPD, Radio, maps:get(Gen, PLG)). % dispatch!

radio_stop(Ctx = #rr{schedule=[]}) -> Ctx;
radio_stop(Ctx) ->
	?LOG_INFO("stop radio"),
	Ctx#rr{schedule = []}.

radio_check_song(Ctx, undefined) -> Ctx;
radio_check_song(Ctx = #rr{schedule=[]}, _Song) -> Ctx;
radio_check_song(Ctx = #rr{schedule=[H|T]}, URI) ->
	?LOG_DEBUG("radio check song have=~s search=~s", [URI, H]),
	case URI of
	% matches, advance in playlist, enqueue next
	H      -> radio_enqueue(Ctx#rr{schedule = T});
	% may come up later...
	_Other -> Ctx
	end.

handle_info(_Message, Ctx)            -> {noreply, Ctx}.
code_change(_OldVersion, Ctx, _Extra) -> {ok, Ctx}.
