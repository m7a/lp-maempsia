-module(maempsia_pl_albums_hits).
-export([generate/3]).
-include_lib("kernel/include/logger.hrl").

% TODO x undocumented bug/assumption: highly rated individual songs can bypass filter. This is currently true for the Ma_Sys.ma deployment and improves performance (no need to check is performed if individual songs may be included per the filters...).

generate(MPD, GRC, _PLRC) ->
	Len          = maps:get(schedule_len, GRC),
	Filter       = maps:get(filter,       GRC),
	{ok, Conn}   = maempsia_erlmpd:connect(MPD),
	AlbumTable1  = find_highly_rated_albums(Conn, Filter),
	{SongTable, AlbumTable2} = find_highly_rated_songs(Conn, Filter,
								AlbumTable1),
	AlbumTable3  = maps:filter(fun(_Key, Playcount) ->
				Playcount =/= not_included end, AlbumTable2),
	RankedSongs  = play_count_table_to_ranked_list(SongTable),
	RankedAlbums = play_count_table_to_ranked_list(AlbumTable3),
	URIS = merge_by_progress(Conn, Filter, RankedSongs, RankedAlbums, Len),
	erlmpd:disconnect(Conn),
	lists:flatten(lists:reverse(URIS)).

find_highly_rated_albums(Conn, Filter) ->
	 lists:foldl(fun(StickerMeta, AlbumTable) ->
			find_and_add_album(Conn, Filter,
				{raw, proplists:get_value(file, StickerMeta)},
				fun add_album/3, AlbumTable)
		end, maps:new(),
		erlmpd:sticker_find(Conn, "filter", {raw, <<>>},
							"rating", gt, "6", [])).

find_and_add_album(Conn, Filter, AlbumFilter, CB, AlbumTable) ->
	BaseFilter = {land, [Filter, AlbumFilter]},
	case erlmpd:find_ex(Conn, BaseFilter, [{window, {0, 8}}]) of
	[]    -> AlbumTable;
	SMeta -> CB(Conn, SMeta, AlbumTable)
	end.

add_album(Conn, SMeta = [S1|_Rem], AlbumTable) ->
	case maempsia_erlmpd:make_album_key(S1) of
	undefined -> AlbumTable;
	Key1 ->
		case maps:is_key(Key1, AlbumTable) of
		true ->
			?LOG_WARNING("duplicate rating - is this key unique?: <"
							++ "~p>", [Key1]),
			AlbumTable;
		false ->
			add_album_no_check(Conn, SMeta, AlbumTable, Key1)
		end
	end.

add_album_no_check(Conn, SMeta, ATbl, Key1) ->
	maps:put(Key1, lists:sum([maempsia_erlmpd:get_playcount(Conn,
			proplists:get_value(file, Line)) || Line <- SMeta])
			div length(SMeta), ATbl).

find_highly_rated_songs(Conn, Filter, AlbumTable1) ->
	foldl_highly_rated_songs(Conn, fun(SMeta, {STbl, ATbl}) ->
		case maempsia_erlmpd:make_album_key(SMeta) of
		undefined -> {add_song(Conn, SMeta, STbl), ATbl};
		Key ->
			case maps:get(Key, ATbl, undefined) of
			undefined ->
				case check_whether_to_include_full_album(Conn,
								Filter, Key) of
				false   -> {add_song(Conn, SMeta, STbl),
						maps:put(Key,
						not_included, ATbl)};
				AFilter -> {STbl, find_and_add_album(Conn,
						Filter, AFilter, fun(C, M, A) ->
						add_album_no_check(C, M, A, Key)
						end, ATbl)}
				end;
			not_included ->
				% easy - already processed before, just include
				% in songs list
				{add_song(Conn, SMeta, STbl), ATbl};
			{true, _EAPC} ->
				% skip - already included
				{STbl, ATbl}
			end
		end
	end, {maps:new(), AlbumTable1}).

foldl_highly_rated_songs(Conn, CB, Acc) ->
	foldl_highly_rated_songs(Conn, CB, Acc, 0).
foldl_highly_rated_songs(Conn, CB, Acc0, Offset) ->
	case erlmpd:sticker_find(Conn, "song", "", "rating", gt, "6",
					[{window, {Offset, Offset + 100}}]) of
	[]    -> Acc0;
	Lines -> foldl_highly_rated_songs(Conn, CB,
				lists:foldl(CB, Acc0, Lines), Offset + 100)
	end.

add_song(Conn, SMeta, STable) ->
	URI = proplists:get_value(file, SMeta),
	maps:put(URI, maempsia_erlmpd:get_playcount(Conn, URI), STable).

% return album filter if yes!
check_whether_to_include_full_album(Conn, Filter, Key) ->
	case maempsia_erlmpd:make_album_filter(Key) of
	undefined -> false;
	AFilter ->
		case erlmpd:find(Conn, {land, [Filter, AFilter]}) of
		[] -> false;
		Lines ->
			URIs    = [proplists:get_value(file, L) || L <- Lines],
			URIRat  = [{URI, maempsia_erlmpd:get_rating(Conn,
							URI)} || URI <- URIs],
			AccRat  = length([URI || {URI, Rating} <- URIRat,
							Rating >= 6]),
			HighRat = length([URI || {URI, Rating} <- URIRat,
							Rating >= 8]),
			case HighRat * 100 div AccRat > 60 of
			true  -> AFilter;
			false -> false
			end
		end
	end.

play_count_table_to_ranked_list(Table) ->
	Median = max(1, median(maps:values(Table))),
	{Values, _Ranks} = lists:unzip(lists:sort(fun({_KA, RA}, {_KB, RB}) ->
				RA < RB
			end, maps:to_list(maps:map(fun(_Key, Count) ->
				(Count / Median) + rand:uniform()
			end, Table)))),
	Values.

% https://rosettacode.org/wiki/Averages/Median#Erlang
median(Unsorted) ->
	Sorted = lists:sort(Unsorted),
	Length = length(Sorted),
	Mid = Length div 2,
	Rem = Length rem 2,
	(lists:nth(Mid + Rem, Sorted) + lists:nth(Mid + 1, Sorted)) / 2.

merge_by_progress(Conn, Filter, RankedSongs, RankedAlbums, Len) ->
	SongsTotal  = length(RankedSongs),
	AlbumsTotal = length(RankedAlbums),
	merge_by_progress(Conn, Filter, SongsTotal, AlbumsTotal,
					RankedSongs, RankedAlbums, [], Len).

merge_by_progress(_Conn, _Filter, _ST, _AT, _RS, _RA, Result, Len)
								when Len =< 0 ->
	Result;
merge_by_progress(_Conn, _Filter, _ST, _AT, [], [], Result, _Len) ->
	Result;
merge_by_progress(Conn, Filter, ST, AT, [RS|T], [], Result, Len) ->
	merge_by_progress(Conn, Filter, ST, AT, T, [], [RS|Result], Len - 1);
merge_by_progress(Conn, Filter, ST, AT, [], [RA|T], Result, Len) ->
	URIS = uris_for_album(Conn, Filter, RA),
	merge_by_progress(Conn, Filter, ST, AT, [], T, [URIS|Result],
							Len - length(URIS));
merge_by_progress(Conn, Filter, ST, AT, [RSH|RST]=RS, RA, Result, Len)
		when ((ST - length(RS)) / ST) > ((AT - length(RA)) / AT) ->
	merge_by_progress(Conn, Filter, ST, AT, RST, RA, [RSH|Result], Len - 1);
merge_by_progress(Conn, Filter, ST, AT, RS, [RAH|RAT], Result, Len) ->
	URIS = uris_for_album(Conn, Filter, RAH),
	merge_by_progress(Conn, Filter, ST, AT, RS, RAT, [URIS|Result],
							Len - length(URIS)).

uris_for_album(Conn, Filter, AlbumKey) ->
	% TODO x converts rather often between key and filter, mabye it could be made more efficient by establishing filter as the primary key - it would be slightly less robust but more “correct” wrt. “first song makes album” not being a generally valid way to obtain the filter i.e. if there is a better filter in the DB it might be preferrable over our synthetic ones...?
	AFilter = maempsia_erlmpd:make_album_filter(AlbumKey),
	URIs    = [proplists:get_value(file, Line) || Line <-
				erlmpd:find(Conn, {land, [Filter, AFilter]})],
	{ReverseRemove, false} = lists:foldl(fun(URI, {Acc, IsActive}) ->
			case IsActive of
			true -> case maempsia_erlmpd:get_rating(Conn, URI)
									< 6 of
				true  -> {[URI|Acc], true};
				false -> {Acc, false}
				end;
			false -> {Acc, false}
			end
		end, {[], true}, lists:reverse(URIs)),
	URIs -- ReverseRemove.
