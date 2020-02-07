
-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

-ifdef(TEST).
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.
-include_lib("eunit/include/eunit.hrl").
-endif.
