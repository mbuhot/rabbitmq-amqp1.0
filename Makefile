PACKAGE=rabbit_amqp1_0
APPNAME=rabbit_amqp1_0
DEPS=rabbitmq-server rabbitmq-erlang-client

# EXTRA_PACKAGE_DIRS=priv

EXTRA_TARGETS=ebin/rabbit_amqp1_0_framing0.beam

START_RABBIT_IN_TESTS=true
TEST_APPS=rabbit_amqp1_0 amqp_client
UNIT_TEST_COMMANDS=eunit:test(rabbit_amqp1_0_test,[verbose])

FRAMING_ERL=src/rabbit_amqp1_0_framing0.erl
FRAMING_HRL=include/rabbit_amqp1_0_framing.hrl
CODEGEN=./codegen.py
CODEGEN_SPECS=spec/messaging.xml spec/transport.xml

EXTRA_BUILD_DEPS=$(FRAMING_HRL)

include ../include.mk

test: unittest

unittest: $(TARGETS) $(TEST_TARGETS)
	ERL_LIBS=$(LIBS_PATH) $(ERL) $(TEST_LOAD_PATH) \
		$(foreach CMD,$(UNIT_TEST_COMMANDS),-eval '$(CMD)') \
		-eval 'init:stop()' | tee $(TMPDIR)/rabbit-amqp1.0-unittest-output |\
			egrep "passed" >/dev/null

$(FRAMING_ERL): $(CODEGEN) $(CODEGEN_SPECS)
	$(CODEGEN) erl $(CODEGEN_SPECS) > $@

$(FRAMING_HRL): $(CODEGEN) $(CODEGEN_SPECS)
	$(CODEGEN) hrl $(CODEGEN_SPECS) > $@

clean::
	rm -f $(FRAMING_HRL) $(FRAMING_ERL)