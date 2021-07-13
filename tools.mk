REBAR ?= ./rebar3

.PHONY: test docs xref dialyzer \
		cleanplt

test: compile
	${REBAR} eunit

docs:
	${REBAR} doc

xref: compile
	${REBAR} xref

dialyzer: 
	${REBAR} dialyzer
