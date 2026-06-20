-module(maempsia_pl_albums_hits).
-export([generate/3]).

-record(ralbum, {key, candidates, uris, playcount}).

generate(MPD, GRC, _PLRC) ->
	%Len     = maps:get(schedule_len, GRC),
	Filter  = maps:get(filter,       GRC),
	ets:new(ralbums, [set, private, named_table, {keypos, #ralbum.key}]),
	{ok, Conn} = maempsia_erlmpd:connect(MPD),
	foreach_highly_rated_song(Conn, fun(URI) ->
		case erlmpd:find(Conn, {land, [Filter, {fileeq, URI}]}) of
		[SMeta1] -> update_db(SMeta1, fun(URIs) -> URIs ++ [URI] end,
			fun(Key1) ->
				case maempsia_erlmpd:make_album_filter(Key1) of
				undefined -> next;
				AFilter1 ->
					Count = erlmpd:count(Conn,
						{land, [Filter, AFilter1]}),
					true = ets:insert_new(ralbums, #ralbum{
						key = Key1, candidates = Count,
						uris = [URI], playcount = 0})
				end
			end);
		_Other -> next
		end
	end),
	foreach_highly_rated_album(Conn, fun(AFilter2) ->
		BaseFilter = {land, [Filter, AFilter2]},
		case erlmpd:find_ex(Conn, BaseFilter, [{window, {0, 1}}]) of
		[] -> next;
		[SMeta2] -> update_db(SMeta2,
			fun(_URIs) -> [proplists:get_value(uri, Line) ||
				Line <- erlmpd:find(Conn, BaseFilter)] end,
			fun(Key2) ->
				Sg = [proplists:get_value(uri, Line) ||
					Line <- erlmpd:find(Conn, BaseFilter)],
				true = ets:insert(ralbums, #ralbum{key =
					Key2, candidates = length(Sg),
					uris = Sg, playcount = 0})
			end)
		end
	end),
	% TODO IMPLEMENT CUTOFF 2 stars ranked ending like in the original script
	% TODO ASSIGN PLAY COUNT TO ALL ALBUMS -- COMPUTE A RANKING, SHUFFLE AND APPLY RANKING, OUTPUT PLAYLIST...
	ets:delete(ralbums),
	erlmpd:disconnect(Conn).
	%maempsia_erlmpd:foreach_song(Conn, Filter, fun(Entry) ->

foreach_highly_rated_song(Conn, CB) ->
	foreach_highly_rated_song(Conn, CB, 0).

foreach_highly_rated_song(Conn, CB, Offset) ->
	case [proplists:get_value(file, Line) || Line <-
			erlmpd:sticker_find(Conn, "song", "", "rating", gt, "6",
			[{sort, uri}, {window, {Offset, Offset + 100}}])] of
	[] -> true;
	URIs ->
		lists:foreach(CB, URIs),
		foreach_highly_rated_song(Conn, CB, Offset + 100)
	end.

foreach_highly_rated_album(Conn, CB) ->
	lists:foreach(CB,
		erlmpd:stick_find(Conn, "filter", "", "rating", gt, "6", [])).

update_db(SMeta, CBUpdate, CBInsert) ->
	case maempsia_erlmpd:make_album_key(SMeta) of
	undefined -> next;
	Key ->
		case ets:lookup(ralbums, Key) of
		[] -> CBInsert(Key);
		[Entry] ->
			LURIs = length(Entry#ralbum.uris),
			case Entry#ralbum.candidates of
			LURIs -> next;
			_Candidates -> true = ets:update_element(ralbums, Key,
				[{#ralbum.uris, CBUpdate(Entry#ralbum.uris)}])
			end
		end
	end.
