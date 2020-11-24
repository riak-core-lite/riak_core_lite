COVERPATH = ./_build/test/cover
REBAR ?= ./rebar3

.PHONY: deps test docs xref dialyzer format

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

proper:
	${REBAR} as proper do eunit
  
epc:
	${REBAR} as epc eunit
	
format:
	${REBAR} format

test: compile
	${REBAR} eunit

coverage: compile
	cp _build/proper+test/cover/eunit.coverdata ${COVERPATH}/proper.coverdata ;\
	${REBAR} cover --verbose

docs:
	${REBAR} edoc

xref: compile
	${REBAR} xref

dialyzer:
	${REBAR} dialyzer

lint:
	${REBAR} lint
