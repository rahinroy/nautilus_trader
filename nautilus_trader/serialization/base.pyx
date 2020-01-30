# -------------------------------------------------------------------------------------------------
# <copyright file="base.pyx" company="Nautech Systems Pty Ltd">
#  Copyright (C) 2015-2020 Nautech Systems Pty Ltd. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  https://nautechsystems.io
# </copyright>
# -------------------------------------------------------------------------------------------------

import re
from nautilus_trader.core.message cimport Command, Event, Request, Response
from nautilus_trader.model.order cimport Order
from nautilus_trader.model.objects cimport Instrument


cdef class Serializer:
    """
    The base class for all serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the Serializer class.
        """
        self._re_camel_to_snake = re.compile(r'(?<!^)(?=[A-Z])')

    cdef str convert_camel_to_snake(self, str value):
        return self._re_camel_to_snake.sub('_', value).upper()

    cdef str convert_snake_to_camel(self, str value):
        cdef list components = value.split('_')
        cdef str x
        return ''.join(x.title() for x in components)

    cpdef str py_convert_camel_to_snake(self, str value):
        return self.convert_camel_to_snake(value)

    cpdef str py_convert_snake_to_camel(self, str value):
        return self.convert_snake_to_camel(value)


cdef class QuerySerializer(Serializer):
    """
    The base class for all query serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the QuerySerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, dict query):
        """
        Serialize the given data query to bytes.

        :param query: The data query to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef dict deserialize(self, bytes query_bytes):
        """
        Deserialize the given bytes to a data query.

        :param query_bytes: The data query bytes to deserialize.
        :return Dict.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")


cdef class DataSerializer(Serializer):
    """
    The base class for all data serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the DataSerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, dict data):
        """
        Serialize the given data mapping to bytes.

        :param data: The data to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef dict deserialize(self, bytes data_bytes):
        """
        Deserialize the given bytes to a mapping of data.

        :param data_bytes: The data bytes to deserialize.
        :return Dict.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")


cdef class InstrumentSerializer(Serializer):
    """
    The base class for all instrument serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the InstrumentSerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, Instrument instrument):
        """
        Serialize the given event to bytes.

        :param instrument: The instrument to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef Instrument deserialize(self, bytes instrument_bytes):
        """
        Deserialize the given instrument bytes to an instrument.

        :param instrument_bytes: The bytes to deserialize.
        :return Instrument.
        """
        # Raise exception if not overridden in implementation.
        raise NotImplementedError("Method must be implemented in the subclass.")


cdef class OrderSerializer(Serializer):
    """
    The base class for all order serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the OrderSerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, Order order):
        """
        Serialize the given order to bytes.

        :param order: The order to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef Order deserialize(self, bytes order_bytes):
        """
        Deserialize the given bytes to an order.

        :param order_bytes: The bytes to deserialize.
        :return Order.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass. ")


cdef class CommandSerializer(Serializer):
    """
    The base class for all command serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the CommandSerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, Command command):
        """
        Serialize the given command to bytes.

        :param command: The command to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef Command deserialize(self, bytes command_bytes):
        """
        Deserialize the given bytes to a command.

        :param command_bytes: The command bytes to deserialize.
        :return Command.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")


cdef class EventSerializer(Serializer):
    """
    The base class for all event serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the EventSerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, Event event):
        """
        Serialize the given event to bytes.

        :param event: The event to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef Event deserialize(self, bytes event_bytes):
        """
        Deserialize the given bytes to an event.

        :param event_bytes: The bytes to deserialize.
        :return Event.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")


cdef class RequestSerializer(Serializer):
    """
    The base class for all request serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the RequestSerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, Request request):
        """
        Serialize the given request to bytes.

        :param request: The request to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef Request deserialize(self, bytes request_bytes):
        """
        Deserialize the given bytes to a request.

        :param request_bytes: The bytes to deserialize.
        :return Request.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")


cdef class ResponseSerializer(Serializer):
    """
    The base class for all response serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the ResponseSerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, Response response):
        """
        Serialize the given response to bytes.

        :param response: The response to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef Response deserialize(self, bytes response_bytes):
        """
        Deserialize the given bytes to a response.

        :param response_bytes: The bytes to deserialize.
        :return Response.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")


cdef class LogSerializer(Serializer):
    """
    The base class for all log message serializers.
    """

    def __init__(self):
        """
        Initializes a new instance of the LogSerializer class.
        """
        super().__init__()

    cpdef bytes serialize(self, LogMessage message):
        """
        Serialize the given message to bytes.

        :param message: The message to serialize.
        :return bytes.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")

    cpdef LogMessage deserialize(self, bytes message_bytes):
        """
        Deserialize the given bytes to a response.

        :param message_bytes: The bytes to deserialize.
        :return LogMessage.
        """
        # Raise exception if not overridden in implementation
        raise NotImplementedError("Method must be implemented in the subclass.")
