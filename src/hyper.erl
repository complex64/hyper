-module(hyper).
-include_lib("eunit/include/eunit.hrl").

-export([new/1, insert/2, card/1, union/2]).
-export([to_json/1, from_json/1]).

-record(hyper, {p, registers}).

new(P) when 4 =< P andalso P =< 16 ->
    M = trunc(pow(2, P)),
    Registers = array:new([{size, M}, {fixed, true}, {default, 0}]),
    #hyper{p = P, registers = Registers}.


insert(Value, #hyper{registers = Registers, p = P} = Hyper) ->
    Hash = erlang:phash2(Value, 4294967296), % 2^32
    <<Index:P, RegisterValue/bitstring>> = <<Hash:32>>,

    ZeroCount = run_of_zeroes(RegisterValue) + 1,

    case array:get(Index, Hyper#hyper.registers) < ZeroCount of
        true ->
            Hyper#hyper{registers = array:set(Index, ZeroCount, Registers)};
        false ->
            Hyper
    end.

union(#hyper{registers = LeftRegisters} = Left,
      #hyper{registers = RightRegisters} = Right) when
      Left#hyper.p =:= Right#hyper.p ->

    NewRegisters = array:map(fun (Index, LeftValue) ->
                                     max(LeftValue,
                                         array:get(Index, RightRegisters))
                             end, LeftRegisters),

    Left#hyper{registers = NewRegisters}.

card(#hyper{registers = Registers, p = P}) ->
    RegistersPow2 =
        lists:map(fun (Register) ->
                          pow(2, -Register)
                  end, array:to_list(Registers)),
    RegisterSum = lists:sum(RegistersPow2),

    M = trunc(pow(2, P)),
    DVEst = alpha(M) * pow(M, 2) * (1 / RegisterSum),

    TwoPower32 = pow(2, 32),

    if
        DVEst < 5/2 * M ->
            ZeroRegisters =
                length(
                  lists:filter(fun (Register) -> Register =:= 0 end,
                               array:to_list(Registers))),
            case ZeroRegisters of
                0 ->
                    DVEst;
                _ ->
                    M * math:log(M / ZeroRegisters)
            end;
        DVEst =< (1/30 * TwoPower32) ->
            DVEst;
        DVEst >= (1/30 * TwoPower32) ->
            pow(-2, 32) * math:log(1 - DVEst/TwoPower32)
    end.


%%
%% SERIALIZATION
%%

to_json(Hyper) ->
    {[
      {<<"p">>, Hyper#hyper.p},
      {<<"registers">>, array:to_list(array:resize(Hyper#hyper.registers))}
     ]}.

from_json({Struct}) ->
    P = proplists:get_value(<<"p">>, Struct),
    M = trunc(math:pow(2, P)),
    Registers = array:fix(
                  array:resize(
                    M, array:from_list(
                         proplists:get_value(<<"registers">>, Struct), 0))),

    #hyper{p = P, registers = Registers}.


alpha(16) -> 0.673;
alpha(32) -> 0.697;
alpha(64) -> 0.709;
alpha(M)  -> 0.7213 / (1 + 1.079 / M).

%%
%% HELPERS
%%


pow(X, Y) ->
    math:pow(X, Y).



run_of_zeroes(B) ->
    run_of_zeroes(1, B).

run_of_zeroes(I, B) ->
    case B of
        <<0:I, _/bitstring>> ->
            run_of_zeroes(I + 1, B);
        _ ->
            I - 1
    end.


%%
%% TESTS
%%

basic_test() ->
    ?assertEqual(1, trunc(card(insert(1, new(4))))).


serialization_test() ->
    Hyper = insert_many(generate_unique(1024), new(14)),
    ?assertEqual(trunc(card(Hyper)), trunc(card(from_json(to_json(Hyper))))).


%% ranges_test_() ->
%%     {timeout, 60000,
%%      fun() ->
%%              Card = 1000000,
%%              {GenerateUsec, Values} = timer:tc(fun () -> generate_unique(Card) end),
%%              error_logger:info_msg("generated ~p unique in ~.2f ms~n",
%%                                    [Card, GenerateUsec / 1000]),

%%              {Usec, Hyper} = timer:tc(
%%                                fun () ->
%%                                        lists:foldl(fun (V, H) ->
%%                                                            insert(V, H)
%%                                                    end,
%%                                                    new(16), Values)
%%                                end),
%%              error_logger:info_msg("true distinct: ~p, estimated: ~p, in ~.2f ms~n"
%%                                    "~.2f per second~n",
%%                                    [Card, card(Hyper), Usec / 1000,
%%                                     Card / (Usec / 1000 / 1000)])
%%      end}.




union_test() ->
    random:seed(1, 2, 3),

    LeftDistinct = sets:from_list(
                     [random:uniform(10000) || _ <- lists:seq(1, 10*1000)]),

    RightDistinct = sets:from_list(
                      [random:uniform(5000) || _ <- lists:seq(1, 10000)]),

    LeftHyper = insert_many(sets:to_list(LeftDistinct),
                            new(16)),

    RightHyper = insert_many(sets:to_list(RightDistinct),
                             new(16)),

    UnionHyper = union(LeftHyper, RightHyper),
    Intersection = card(LeftHyper) + card(RightHyper) - card(UnionHyper),

    error_logger:info_msg("left distinct: ~p~n"
                          "right distinct: ~p~n"
                          "true union: ~p~n"
                          "true intersection: ~p~n"
                          "estimated union: ~p~n"
                          "estimated intersection: ~p~n",
                          [sets:size(LeftDistinct),
                           sets:size(RightDistinct),
                           sets:size(
                             sets:union(LeftDistinct, RightDistinct)),
                           sets:size(
                             sets:intersection(LeftDistinct, RightDistinct)),
                           card(UnionHyper),
                           Intersection
                          ]).

%% report_wrapper_test_() ->
%%     [{timeout, 600000000, ?_test(estimate_report())}].

estimate_report() ->
    random:seed(erlang:now()),
    Ps = lists:seq(4, 16, 1),
    Cardinalities = [100, 1000, 10000, 100000, 1000000],
    Repetitions = 60,

    %% Ps = [4, 5],
    %% Cardinalities = [100],
    %% Repetitions = 100,

    Stats = [run_report(P, Card, Repetitions) || P <- Ps,
                                                 Card <- Cardinalities],
    error_logger:info_msg("~p~n", [Stats]),

    Result =
        "p,card,mean,p99,p1,bytes~n" ++
        lists:map(fun ({P, Card, Mean, P99, P1, Bytes}) ->
                          io_lib:format("~p,~p,~.2f,~.2f,~.2f,~p~n",
                                        [P, Card, Mean, P99, P1, Bytes])
                  end, Stats),
    error_logger:info_msg(Result),
    ok = file:write_file("../data.csv", io_lib:format(Result, [])).

run_report(P, Card, Repetitions) ->
    Estimations = lists:map(fun (_) ->
                                    Elements = generate_unique(Card),
                                    abs(Card - card(insert_many(Elements, new(P))))
                            end, lists:seq(1, Repetitions)),
    error_logger:info_msg("p=~p, card=~p, reps=~p~nestimates=~p~n",
                          [P, Card, Repetitions, Estimations]),
    Hist = basho_stats_histogram:update_all(
             Estimations,
             basho_stats_histogram:new(
               0,
               lists:max(Estimations),
               length(Estimations))),


    {_, Mean, _, _, Sd} = basho_stats_histogram:summary_stats(Hist),
    P99 = basho_stats_histogram:quantile(0.99, Hist),
    P1 = basho_stats_histogram:quantile(0.01, Hist),

    {P, Card, Mean, P99, P1, trunc(pow(2, P))}.


generate_unique(N) ->
    generate_unique(lists:usort(random_bytes(N)), N).


generate_unique(L, N) ->
    case length(L) of
        N ->
            L;
        Less ->
            generate_unique(lists:usort(random_bytes(N - Less) ++ L), N)
    end.


random_bytes(N) ->
    random_bytes([], N).

random_bytes(Acc, 0) -> Acc;
random_bytes(Acc, N) ->
    Int = random:uniform(100000000000000),
    random_bytes([<<Int:64/integer>> | Acc], N-1).





insert_many(L, Hyper) ->
    lists:foldl(fun insert/2, Hyper, L).
                        
