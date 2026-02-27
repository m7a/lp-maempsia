-module(maempsia_pl_radio).
-export([generate/3]).
-include_lib("stdlib/include/ms_transform.hrl").
-define(RATING_UNRATED, -1).
-record(rsong, {uri, play_count, rating}).

% GRC  := general radio config (schedule_len has playlist target length)
% PLRC := playlist radio config, returns list of URIs
generate(MPD, GRC, PLRC) ->
	Len     = maps:get(schedule_len, GRC),
	Filter  = maps:get(filter,       GRC),
	Pattern = maps:get(pattern,      PLRC),
	ets:new(rsongs, [set, private, named_table, {keypos, #rsong.uri}]),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	maempsia_erlmpd:foreach_song(Conn, Filter, fun(Entry) ->
		URI = proplists:get_value(file, Entry),
		insert_rated(Conn, URI, maempsia_erlmpd:get_rating(Conn, URI))
	end),
	State = {
		{query_by_rat_eq(0, 0), 0, 1},
		{query_by_rat_eq(1, 0), 0, 1},
		{query_by_rat_eq(2, 0), 0, 1},
		Pattern
	},
	RV = generate_inner(Len, Pattern, State, []),
	ets:delete(rsongs),
	RV.

insert_rated(_Conn, _URI, Rating)
			when (Rating /= ?RATING_UNRATED) and (Rating < 4) ->
	true; % skip songs which are rated below 2 stars
insert_rated(Conn, URI, Rating) ->
	true = ets:insert_new(rsongs, #rsong{
		uri        = URI,
		play_count = maempsia_erlmpd:get_playcount(Conn, URI),
		rating     = transform_rating(Rating)
	}).

transform_rating(R) when (R == ?RATING_UNRATED) or (R == 5) or (R == 6) -> 1;
transform_rating(R) when R >= 7 -> 2;
transform_rating(_R) -> 0.

query_by_rat_eq(Rating, PlayCount) ->
	shuffle(ets:select(rsongs, ets:fun2ms(
		fun(X) when (X#rsong.rating == Rating) and
			(X#rsong.play_count == PlayCount) -> X#rsong.uri end))).

% https://stackoverflow.com/questions/8817171/shuffling-elements-in-a-list-
shuffle(List) ->
	[X || {_Rnd, X} <- lists:sort([{rand:uniform(), N} || N <- List])].

generate_inner(0, _Pat, _State, List) ->
	lists:reverse(List);
generate_inner(Rem, _Pat, _State, _List) when Rem < 0 ->
	{error, {assert_ge_0, Rem}};
generate_inner(Rem, [], State = {_R0, _R1, _R2, Pattern}, List) ->
	generate_inner(Rem, Pattern, State, List);
generate_inner(Rem, [R|Tail], State, List) ->
	{Ent, RX} = proc_rx(R, element(R + 1, State)),
	generate_inner(Rem - 1, Tail, setelement(R + 1, State, RX), [Ent|List]).

proc_rx(X, {[], PlayCount, 0}) ->
	proc_rx(X, {query_by_rat_lt(X, PlayCount), PlayCount, 1});
proc_rx(X, {[], PlayCount, 1}) ->
	proc_rx(X, {query_by_rat_eq(X, PlayCount + 1), PlayCount + 1, 0});
proc_rx(_X, {[H|T], PlayCount, Y}) ->
	{H, {T, PlayCount, Y}}.

query_by_rat_lt(Rating, PlayCount) ->
	shuffle(ets:select(rsongs, ets:fun2ms(
		fun(X) when (X#rsong.rating == Rating) and
			(X#rsong.play_count < PlayCount) -> X#rsong.uri end))).
