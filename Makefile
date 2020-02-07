PULSE_TESTS = worker_pool_pulse

REBAR ?= ./rebar3

.PHONY: deps test docs xref dialyzer

all: compile

compile: deps
	${REBAR} compile

clean: clean-test
	${REBAR} clean


distclean: clean

clean-test:
	rm -rf t1000
	rm -rf t2000
	rm -rf t1
	rm -rf t2
	rm -rf ring_manager_eunit/test.ring
	rm -rf ring_manager_eunit
	rm -rf nonode@nohost
	rm -rf log.nonode@nohost
	rm -rf data.nonode@nohost
	rm -rf data

# You should 'clean' before your first run of this target
# so that deps get built with PULSE where needed.
pulse:
	${REBAR} compile -D PULSE
	${REBAR} eunit -D PULSE skip_deps=true suite=$(PULSE_TESTS)

test: compile
	${REBAR} eunit

coverage: compile
	${REBAR} cover --verbose

docs:
	${REBAR} doc

xref: compile
	${REBAR} xref

dialyzer:
	${REBAR} dialyzer

lint:
	${REBAR} as lint lint
