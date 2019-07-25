PULSE_TESTS = worker_pool_pulse

.PHONY: deps test

all: compile

compile: deps
	./rebar3 compile

clean: clean-test
	./rebar3 clean


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
	./rebar3 compile -D PULSE
	./rebar3 eunit -D PULSE skip_deps=true suite=$(PULSE_TESTS)

include tools.mk
