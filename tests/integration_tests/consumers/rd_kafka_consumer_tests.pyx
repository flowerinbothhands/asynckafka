import socket
import unittest

import asyncio

import time
import uuid
from contextlib import closing

from kafka import KafkaProducer

from asynckafka import exceptions
from asynckafka.consumers.rd_kafka_consumer cimport RdKafkaConsumer
from asynckafka.consumers.rd_kafka_consumer import RdKafkaConsumer
from asynckafka.consumers.consumers cimport Consumer, StreamConsumer
from asynckafka.includes cimport c_rd_kafka as crdk

import os
from subprocess import call


import logging
import sys
logging.basicConfig(stream=sys.stdout, level=logging.DEBUG)


def produce_to_kafka(topic, message, number=1):
    producer = KafkaProducer(bootstrap_servers='localhost:9092')
    [producer.send(topic, message) for _ in range(number)]
    producer.close()


test_consumer_settings = {
    "session.timeout.ms": "6000"
}


test_topic_settings = {
    'auto.offset.reset':  'smallest'
}


class IntegrationTestCase(unittest.TestCase):

    def setUp(self):
        self.test_message = b'some_message_bytes'
        self.test_topic = 'test_' + str(uuid.uuid4())

        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)

    def tearDown(self):
        self.loop.close()


class TestIntegrationRdKafkaConsumer(IntegrationTestCase):

    def tests_start_and_stop(self):
        rd_kafka_consumer = RdKafkaConsumer(
            brokers='127.0.0.1',
            consumer_settings=test_consumer_settings,
            topic_settings=test_topic_settings,
        )
        rd_kafka_consumer.add_topic("my_topic")
        rd_kafka_consumer.start()
        rd_kafka_consumer.stop()


class TestIntegrationConsumer(IntegrationTestCase):

    def setUp(self):
        super().setUp()
        self.consumer = Consumer(
            brokers="127.0.0.1:9092",
            consumer_settings=test_consumer_settings,
            topic_settings=test_topic_settings,
            loop=self.loop,
        )

    def tearDown(self):
        if self.consumer.is_consuming():
            self.consumer.stop()
        super().tearDown()

    def test_consume_one_message(self):
        confirm_message = asyncio.Future(loop=self.loop)

        async def message_handler(message):
            confirm_message.set_result(message)
        self.consumer.add_message_handler(self.test_topic, message_handler)
        self.consumer.start()

        produce_to_kafka(self.test_topic, self.test_message)

        coro = asyncio.wait_for(confirm_message, timeout=10, loop=self.loop)
        self.loop.run_until_complete(coro)

        self.assertEqual(confirm_message.result(), self.test_message)

    def test_consume_one_thousand_of_messages(self):
        n_messages= 1000
        consumed_messages = asyncio.Queue(maxsize=n_messages, loop=self.loop)

        async def message_handler(message):
            consumed_messages.put_nowait(message)
        self.consumer.add_message_handler(self.test_topic, message_handler)
        self.consumer.start()

        produce_to_kafka(self.test_topic, self.test_message, number=1000)

        async def wait_for_messages():
            while True:
                await asyncio.sleep(0.1)
                if consumed_messages.qsize() == n_messages:
                    break

        coro = asyncio.wait_for(
            wait_for_messages(),
            timeout=30,
            loop=self.loop
        )
        self.loop.run_until_complete(coro)

        for _ in range(n_messages):
            self.assertEqual(consumed_messages.get_nowait(), self.test_message)

    def start_without_message_handler_raise_exception(self):
        with self.assertRaises(exceptions.ConsumerError):
            self.consumer.start()

    def test_two_starts_raise_consumer_error(self):
        async def message_handler(message):
            pass
        self.consumer.add_message_handler(self.test_topic, message_handler)
        self.consumer.start()
        with self.assertRaises(exceptions.ConsumerError):
            self.consumer.start()

    def test_stops_raise_consumer_error(self):
        async def message_handler(message):
            pass
        self.consumer.add_message_handler(self.test_topic, message_handler)
        self.consumer.start()
        self.consumer.stop()
        with self.assertRaises(exceptions.ConsumerError):
            self.consumer.stop()

    def test_stop_without_start_raise_consumer_error(self):
        with self.assertRaises(exceptions.ConsumerError):
            self.consumer.stop()


class TestIntegrationStreamConsumer(IntegrationTestCase):

    def setUp(self):
        super().setUp()
        self.stream_consumer = StreamConsumer(
            brokers="127.0.0.1:9092",
            topic=self.test_topic,
            consumer_settings=test_consumer_settings,
            topic_settings=test_topic_settings,
            loop=self.loop,
        )

    def tearDown(self):
        if self.stream_consumer.is_consuming():
            self.stream_consumer.stop()
        super().tearDown()


    def test_consume_one_message(self):
        confirm_message = asyncio.Future(loop=self.loop)

        async def consume_messages():
            async for message in self.stream_consumer:
                confirm_message.set_result(message)

        self.stream_consumer.start()

        produce_to_kafka(self.test_topic, self.test_message)

        asyncio.ensure_future(consume_messages(), loop=self.loop)
        coro = asyncio.wait_for(confirm_message, timeout=10, loop=self.loop)
        self.loop.run_until_complete(coro)

        self.assertEqual(confirm_message.result(), self.test_message)

    def test_consume_one_thousand_of_messages(self):
        n_messages= 1000
        consumed_messages = asyncio.Queue(maxsize=n_messages, loop=self.loop)

        async def consume_messages():
            async for message in self.stream_consumer:
                consumed_messages.put_nowait(message)

        self.stream_consumer.start()

        produce_to_kafka(self.test_topic, self.test_message, number=1000)

        asyncio.ensure_future(consume_messages(), loop=self.loop)

        async def wait_for_messages():
            while True:
                await asyncio.sleep(0.1)
                if consumed_messages.qsize() == n_messages:
                    break

        coro = asyncio.wait_for(
            wait_for_messages(),
            timeout=30,
            loop=self.loop
        )
        self.loop.run_until_complete(coro)

        for _ in range(n_messages):
            self.assertEqual(consumed_messages.get_nowait(), self.test_message)

    def test_two_starts_raise_consumer_error(self):
        self.stream_consumer.start()
        with self.assertRaises(exceptions.ConsumerError):
            self.stream_consumer.start()

    def test_stops_raise_consumer_error(self):
        self.stream_consumer.start()
        self.stream_consumer.stop()
        with self.assertRaises(exceptions.ConsumerError):
            self.stream_consumer.stop()

    def test_stop_without_start_raise_consumer_error(self):
        with self.assertRaises(exceptions.ConsumerError):
            self.stream_consumer.stop()
