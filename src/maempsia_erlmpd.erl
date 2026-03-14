-module(maempsia_erlmpd).
-export([connect/1, foreach_song/3, get_playcount/2, get_rating/2,
	get_album_rating/2, get_album_rating_by_filter/2,
	set_album_rating_by_filter/3, delete_album_rating_by_filter/2,
	get_status_props/1, get_artist/1, normalize_safe/1,
	normalize_strong/1]).
-include_lib("kernel/include/logger.hrl").
-define(RATING_UNRATED, -1).
-define(RATING_NOTPOSS, -2).

connect(MPD) ->
	{Host, Port} = maps:get(ip, MPD),
	case erlmpd:connect(Host, Port) of
	{ok, Conn} ->
		{ok, Conn};
	Error ->
		?LOG_ERROR("Failed to connect to ~p: ~p", [MPD, Error]),
		Error
	end.

% Traverse large output results with efficient WINDOW batch sizes
foreach_song(Conn, Filter, Callback) ->
	Stats    = erlmpd:count(Conn, Filter),
	NumSongs = proplists:get_value(songs, Stats, 0),
	?LOG_INFO("Found ~p songs in the database", [NumSongs]),
	foreach_song_in_db(Conn, Filter, Callback, 0, NumSongs).

foreach_song_in_db(_Conn, _Filter, _CB, _Start, 0) ->
	ok;
foreach_song_in_db(_Conn, _Filter, _CB, _Start, CountRemaining)
						when CountRemaining < 0 ->
	{error, {assert_ge_0, CountRemaining}};
foreach_song_in_db(Conn, Filter, CB, Start, CountRemaining) ->
	Proc = min(CountRemaining, 300), % 200..500 were the fastest batch sizes
	End  = Start + Proc,
	?LOG_INFO("foreach_song_in_db start=~p end=~p proc=~p progress=~f%",
		[Start, End, Proc, Start * 100 / (Start + CountRemaining)]),
	lists:foreach(CB, erlmpd:find_ex(Conn, Filter,
						[{window, {Start, End}}])),
	foreach_song_in_db(Conn, Filter, CB, End, CountRemaining - Proc).

get_playcount(Conn, URI) ->
	case erlmpd:sticker_get(Conn, "song", binary_to_list(URI),
								"playCount") of
	{error, _Any}   -> 0;
	ProperPlaycount -> list_to_integer(ProperPlaycount)
	end.

get_rating(Conn, URI) ->
	case erlmpd:sticker_get(Conn, "song", binary_to_list(URI), "rating") of
	{error, _Any} -> ?RATING_UNRATED;
	ProperRating  -> list_to_integer(ProperRating)
	end.

get_album_rating(Conn, Song) ->
	AlbumArtist = proplists:get_value('AlbumArtist', Song),
	AlbumTitle  = proplists:get_value('Album',       Song),
	case (AlbumArtist =:= undefined) or (AlbumTitle =:= undefined) of
	true  -> ?RATING_NOTPOSS;
	false -> get_album_rating_by_filter(Conn,
				{land, [{tagop, albumartist, eq, AlbumArtist},
					{tagop, album,       eq, AlbumTitle}]})
	end.

get_album_rating_by_filter(Conn, Filter) ->
	case erlmpd:sticker_get(Conn, "filter", Filter, "rating") of
	{error, _Any} -> ?RATING_UNRATED;
	ProperRating  -> list_to_integer(ProperRating)
	end.

set_album_rating_by_filter(Conn, Filter, Rating) ->
	erlmpd:sticker_set(Conn, "filter", Filter, "rating",
						integer_to_list(Rating)).

delete_album_rating_by_filter(Conn, Filter) ->
	erlmpd:sticker_delete(Conn, "filter", Filter, "rating").

get_status_props(Conn) ->
	[{status, erlmpd:status(Conn)},
	{currentsong, erlmpd:currentsong(Conn)}].

get_artist(SongInfo) ->
	case proplists:get_value('AlbumArtist', SongInfo) of
	undefined             -> proplists:get_value('Artist', SongInfo, <<>>);
	<<"Various Artists">> -> proplists:get_value('Artist', SongInfo, <<>>);
	ValidAA               -> ValidAA
	end.

% not strictly-speaking erlmpd related but doesn't make sense to create an own
% file for right now...
normalize_safe(Value) ->
	re:replace(string:replace(string:replace(string:replace(
				lists:join(<<" ">>, string:lexemes(Value, " ")),
			"[", "(", all), "]", ")", all), "’", "'", all),
		" (\\(?feat(\\.|uring)?|vs\\.) .*$", "").

normalize_strong(Value) ->
	re:replace(normalize_safe(Value), " \\(.*\\)$", "").
