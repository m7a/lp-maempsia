-module(maempsia_cache).
-export([init/0, store/2, check_requires_update/2, invalidate/0]).
-define(CACHE_EXPIRY_SEC, 180).

% Since it is really only invoked on demand this cache does not need an own
% process. Put it in an own module to reserve the name of the table and decouple
% it from the remainder of the web interface.

init() ->
	ets:new(?MODULE, [public, named_table, {keypos, 1}, set]).

% returns headers to add
store(Location, Content) ->
	%Size = iolist_size(Content),
	Hash = crypto:hash(sha512, Content),
	HDR  = generate_headers(Hash),
	ets:insert(?MODULE, {Location, HDR}),
	HDR.

check_requires_update(Location, Req) ->
	case ets:lookup(?MODULE, Location) of
	[] ->
		true;
	[{_Location, HDR}] ->
		CMP = ts_str_to_integer(proplists:get_value("Last-Modified",
									HDR)),
		Now = ts_str_to_integer(httpd_util:rfc1123_date()),
		case mochiweb_request:get_header_value("If-None-Match", Req) of
		undefined ->
			case mochiweb_request:get_header_value(
						"If-Modified-Since", Req) of
			undefined ->
				true;
			IfModifiedSince ->
				% return true if CMP > IfModifiedSince
				IfModInt = ts_str_to_integer(IfModifiedSince),
				if
				(IfModInt =< 0) or (CMP > IfModInt) or ((Now -
						CMP) > ?CACHE_EXPIRY_SEC) ->
					invalidate(),
					true;
				true ->
					mochiweb_request:respond({304, HDR, ""},
									Req),
					false
				end
			end;
		IfNoneMatch ->
			case proplists:get_value("ETag", HDR) of
			IfNoneMatch when (Now - CMP) =< ?CACHE_EXPIRY_SEC ->
				mochiweb_request:respond({304, HDR, ""}, Req),
				false;
			_Other ->
				invalidate(),
				true
			end
		end
	end.

invalidate() ->
	ets:delete_all_objects(?MODULE).

% -- private functions running outside of gen server context --
generate_headers(Hash) ->
	[
		{"Last-Modified", httpd_util:rfc1123_date()},
		{"Cache-Control", "max-age=" ++
					integer_to_list(?CACHE_EXPIRY_SEC)},
		{"ETag",          binary_to_list(binary:encode_hex(Hash))}
	].

% https://stackoverflow.com/questions/21827905/erlang-how-can-i-parse-rfc1123-
% Example: "Mon, 17 Feb 2014 11:07:53 GMT"
%ts_str_to_integer(Bin) when is_binary(Bin) ->
%	ts_str_to_integer(binary_to_list(Bin));
ts_str_to_integer(Str) ->
	case re:run(Str, "^([A-Za-z]{3}), ([0-9]{2}) ([A-Za-z]{3}) " ++
			"([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) GMT$",
			[{capture, all, list}]) of
	{match, [_All, _DayOfWeek, DayOfMonthRaw, MonthRaw, YearRaw,
							HHRaw, IIRaw, SSRaw]} ->
		ErlangDateTime = {
			{list_to_integer(YearRaw), month_to_int(MonthRaw),
				list_to_integer(DayOfMonthRaw)},
			{list_to_integer(HHRaw), list_to_integer(IIRaw),
				list_to_integer(SSRaw)}
		},
		calendar:datetime_to_gregorian_seconds(ErlangDateTime);
	nomatch ->
		-1
	end.

month_to_int("Jan") -> 1;
month_to_int("Feb") -> 2;
month_to_int("Mar") -> 3;
month_to_int("Apr") -> 4;
month_to_int("May") -> 5;
month_to_int("Jun") -> 6;
month_to_int("Jul") -> 7;
month_to_int("Aug") -> 8;
month_to_int("Sep") -> 9;
month_to_int("Oct") -> 10;
month_to_int("Nov") -> 11;
month_to_int("Dec") -> 12.
