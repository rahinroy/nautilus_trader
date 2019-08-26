# -------------------------------------------------------------------------------------------------
# <copyright file="execution.pyx" company="Nautech Systems Pty Ltd">
#  Copyright (C) 2015-2019 Nautech Systems Pty Ltd. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  https://nautechsystems.io
# </copyright>
# -------------------------------------------------------------------------------------------------

import queue
import threading

from redis import Redis
from zmq import Context

from nautilus_trader.core.correctness cimport Condition
from nautilus_trader.core.message cimport MessageType, Message, Command, Event, Response
from nautilus_trader.model.order cimport Order
from nautilus_trader.model.position cimport Position
from nautilus_trader.model.identifiers cimport TraderId, StrategyId, OrderId, PositionId
from nautilus_trader.model.commands cimport (
    Command,
    AccountInquiry,
    SubmitOrder,
    SubmitAtomicOrder,
    ModifyOrder,
    CancelOrder)
from nautilus_trader.model.events cimport (
    Event,
    OrderEvent,
    OrderFillEvent,
    OrderInitialized,
    PositionEvent,
    AccountStateEvent,
    OrderModified,
    OrderRejected,
    OrderCancelled,
    OrderCancelReject,
    PositionOpened,
    PositionModified,
    PositionClosed)
from nautilus_trader.common.account cimport Account
from nautilus_trader.common.clock cimport Clock
from nautilus_trader.common.guid cimport GuidFactory
from nautilus_trader.common.logger cimport Logger
from nautilus_trader.common.execution cimport ExecutionDatabase, ExecutionEngine, ExecutionClient
from nautilus_trader.common.portfolio cimport Portfolio
from nautilus_trader.network.workers cimport RequestWorker, SubscriberWorker
from nautilus_trader.serialization.base cimport CommandSerializer, ResponseSerializer
from nautilus_trader.serialization.serializers cimport MsgPackCommandSerializer, MsgPackResponseSerializer
from nautilus_trader.live.logger cimport LiveLogger
from nautilus_trader.serialization.serializers cimport EventSerializer, MsgPackEventSerializer
from nautilus_trader.trade.strategy cimport TradingStrategy

cdef str UTF8 = 'utf-8'

cdef str TRADER = 'Trader'
cdef str INDEX = 'Index'
cdef str CONFIG = 'Config'
cdef str ACCOUNTS = 'Accounts'
cdef str ORDERS = 'Orders'
cdef str POSITIONS = 'Positions'
cdef str STRATEGIES = 'Strategies'
cdef str ORDER_POSITION = 'OrderPosition'
cdef str ORDER_STRATEGY = 'OrderStrategy'
cdef str POSITION_ORDERS = 'PositionOrders'
cdef str POSITION_STRATEGY = 'PositionStrategy'
cdef str STRATEGY_ORDERS = 'StrategyOrders'
cdef str STRATEGY_POSITIONS = 'StrategyPositions'
cdef str WORKING = 'Working'
cdef str COMPLETED = 'Completed'
cdef str OPEN = 'Open'
cdef str CLOSED = 'Closed'


cdef class RedisExecutionDatabase(ExecutionDatabase):
    """
    Provides an execution database utilizing Redis.
    """

    def __init__(self,
                 TraderId trader_id,
                 str host,
                 int port,
                 CommandSerializer command_serializer,
                 EventSerializer event_serializer,
                 Logger logger,
                 bint load_cache=True,
                 bint check_integrity=True):
        """
        Initializes a new instance of the RedisExecutionEngine class.

        :param trader_id: The trader identifier.
        :param port: The redis host for the database connection.
        :param port: The redis port for the database connection.
        :param command_serializer: The command serializer for database transactions.
        :param event_serializer: The event serializer for database transactions.
        :raises ConditionFailed: If the host is not a valid string.
        :raises ConditionFailed: If the port is not in range [0, 65535].
        """
        Condition.valid_string(host, 'host')
        Condition.in_range(port, 'port', 0, 65535)

        super().__init__(trader_id, logger)

        # Database keys
        self.key_trader                   = f'{TRADER}-{trader_id.value}'
        self.key_accounts                 = f'{self.key_trader}:{ACCOUNTS}:'
        self.key_orders                   = f'{self.key_trader}:{ORDERS}:'
        self.key_positions                = f'{self.key_trader}:{POSITIONS}:'
        self.key_strategies               = f'{self.key_trader}:{STRATEGIES}:'
        self.key_index_order_position     = f'{self.key_trader}:{INDEX}:{ORDER_POSITION}'      # HASH
        self.key_index_order_strategy     = f'{self.key_trader}:{INDEX}:{ORDER_STRATEGY}'      # HASH
        self.key_index_position_strategy  = f'{self.key_trader}:{INDEX}:{POSITION_STRATEGY}'   # HASH
        self.key_index_position_orders    = f'{self.key_trader}:{INDEX}:{POSITION_ORDERS}:'    # SET
        self.key_index_strategy_orders    = f'{self.key_trader}:{INDEX}:{STRATEGY_ORDERS}:'    # SET
        self.key_index_strategy_positions = f'{self.key_trader}:{INDEX}:{STRATEGY_POSITIONS}:' # SET
        self.key_index_orders             = f'{self.key_trader}:{INDEX}:{ORDERS}'              # SET
        self.key_index_orders_working     = f'{self.key_trader}:{INDEX}:{ORDERS}:{WORKING}'    # SET
        self.key_index_orders_completed   = f'{self.key_trader}:{INDEX}:{ORDERS}:{COMPLETED}'  # SET
        self.key_index_positions          = f'{self.key_trader}:{INDEX}:{POSITIONS}'           # SET
        self.key_index_positions_open     = f'{self.key_trader}:{INDEX}:{POSITIONS}:{OPEN}'    # SET
        self.key_index_positions_closed   = f'{self.key_trader}:{INDEX}:{POSITIONS}:{CLOSED}'  # SET

        # Serializers
        self._command_serializer = command_serializer
        self._event_serializer = event_serializer

        # Redis client
        self._redis = Redis(host=host, port=port, db=0)

        self.load_cache = load_cache
        self.check_integrity = check_integrity

        # Load cache
        if self.load_cache:
            self.load_orders_cache()
            self.load_positions_cache()


# -- COMMANDS -------------------------------------------------------------------------------------"

    cpdef void load_orders_cache(self):
        """
        Clear the current order cache and load orders from the database.
        """
        self._cached_orders.clear()

        cdef bytes key_bytes
        cdef str key
        cdef bytes event_bytes
        cdef list events
        cdef Order order
        cdef OrderEvent initial

        cdef list order_keys = self._redis.keys(f'{self.key_orders}*')

        for key_bytes in order_keys:
            key = key_bytes.decode(UTF8)
            events = self._redis.lrange(name=key, start=0, end=-1)
            initial = self._event_serializer.deserialize(events.pop(0))
            assert isinstance(initial, OrderInitialized)
            order = Order.create(event=initial)

            for event_bytes in events:
                order.apply(self._event_serializer.deserialize(event_bytes))

            self._cached_orders[order.id] = order

    cpdef void load_positions_cache(self):
        """
        Clear the current order cache and load orders from the database.
        """
        self._cached_positions.clear()

        cdef bytes key_bytes
        cdef str key
        cdef bytes event_bytes
        cdef list events
        cdef Position position
        cdef OrderFillEvent initial

        cdef list position_keys = self._redis.keys(f'{self.key_positions}*')

        for key_bytes in position_keys:
            key = key_bytes.decode(UTF8).rsplit(':', maxsplit=1)[1]
            events = self._redis.lrange(name=key, start=0, end=-1)
            initial = self._event_serializer.deserialize(events.pop(0))
            assert isinstance(initial, OrderFillEvent)
            position = Position(position_id=key, event=initial)

            for event in events:
                position.apply(event)

            self._cached_positions[position.id] = position

    cpdef void check_residuals(self):
        # Check for any residual active orders and log warnings if any are found
        for working_orders in self._redis.smembers(self.key_index_orders_working):
            for order_id in working_orders:
                self._log.warning(f"Residual working order {order_id}")

        for positions_open in self._redis.smembers(self.key_index_positions_open):
            for position_id in positions_open:
                self._log.warning(f"Residual open position {position_id}")

    cpdef void reset(self):
        """
        Reset the execution database by clearing the cache.
        """
        self._reset()

    cpdef void flush(self):
        """
        Flush the database which clears all data.
        """
        self._redis.flushdb()

    cpdef void add_strategy(self, TradingStrategy strategy):
        """
        Add the given strategy to the execution database.

        :param strategy: The strategy to add.
        """
        pipe = self._redis.pipeline()
        pipe.hset(self.key_strategies + f'{strategy.id.value}:{CONFIG}', 'some_value', 1)
        pipe.execute()

        self._log.debug(f"Added new {strategy.id}.")

    cpdef void add_order(self, Order order, StrategyId strategy_id, PositionId position_id):
        """
        Add the given order to the execution database.

        :param order: The order to add.
        :param strategy_id: The strategy identifier to associate with the order.
        :param position_id: The position identifier to associate with the order.
        """
        Condition.not_in(order.id, self._cached_orders, 'order.id', 'cached_orders')

        self._cached_orders[order.id] = order

        cdef str key_order =  self.key_orders + order.id.value

        if self.check_integrity:
            if self._redis.exists(key_order):
                self._log.warning(f'The {key_order} already exists.')

        # Command pipeline
        pipe = self._redis.pipeline()
        pipe.rpush(key_order, self._event_serializer.serialize(order.last_event))
        pipe.hset(name=self.key_index_order_position, key=order.id.value, value=position_id.value)
        pipe.hset(name=self.key_index_order_strategy, key=order.id.value, value=strategy_id.value)
        pipe.hset(name=self.key_index_position_strategy, key=position_id.value, value=strategy_id.value)
        pipe.sadd(self.key_index_orders, order.id.value)
        pipe.sadd(self.key_index_position_orders + position_id.value, order.id.value)
        pipe.sadd(self.key_index_strategy_orders + strategy_id.value, order.id.value)
        pipe.sadd(self.key_index_strategy_positions + strategy_id.value, position_id.value)
        pipe.execute()

        self._log.debug(f"Added new {order.id} with {strategy_id} and {position_id}.")

    cpdef void add_position(self, Position position, StrategyId strategy_id):
        """
        Add the given position associated with the given strategy identifier.

        :param position: The position to add.
        :param strategy_id: The strategy identifier to associate with the position.
        """
        Condition.not_in(position.id, self._cached_positions, 'position.id', 'cached_positions')

        self._cached_positions[position.id] = position

        cdef str key_position = self.key_positions + position.id.value

        if self.check_integrity:
            if self._redis.exists(key_position):
                self._log.warning(f'The {key_position} already exists.')

        # Command pipeline
        pipe = self._redis.pipeline()
        pipe.rpush(key_position, self._event_serializer.serialize(position.last_event))
        pipe.sadd(self.key_index_positions, position.id.value)
        pipe.sadd(self.key_index_positions_open, position.id.value)
        pipe.execute()

        self._log.debug(f"Added open {position.id}")

    cpdef void update_order(self, Order order):
        """
        Update the given order in the execution database by persisting its
        last event.

        :param order: The order to update (last event).
        """
        cdef str key_order = self.key_orders + order.id.value

        if self.check_integrity:
            if not self._redis.exists(key_order):
                self._log.warning(f'The {key_order} did not already exist.')

        # Command pipeline
        pipe = self._redis.pipeline()
        pipe.rpush(key_order, self._event_serializer.serialize(order.last_event))
        if order.is_working:
            pipe.sadd(self.key_index_orders_working, order.id.value)
            pipe.srem(self.key_index_orders_completed, order.id.value)
        elif order.is_completed:
            pipe.sadd(self.key_index_orders_completed, order.id.value)
            pipe.srem(self.key_index_orders_working, order.id.value)
        pipe.execute()

    cpdef void update_position(self, Position position):
        """
        Update the given position in the execution database by persisting its
        last event.

        :param position: The position to update (last event).
        """

        cdef str key_position = self.key_positions + position.id.value

        if self.check_integrity:
            if not self._redis.exists(key_position):
                self._log.warning(f'The {key_position} did not already exist.')

        # Command pipeline
        pipe = self._redis.pipeline()
        pipe.rpush(key_position, self._event_serializer.serialize(position.last_event))
        if position.is_closed:
            pipe.sadd(self.key_index_positions_closed, position.id.value)
            pipe.srem(self.key_index_positions_open, position.id.value)
        else:
            pipe.sadd(self.key_index_positions_open, position.id.value)
            pipe.srem(self.key_index_positions_closed, position.id.value)
        pipe.execute()

    cpdef void update_account(self, Account account):
        """
        Update the given account in the execution database by persisting its
        last event.

        :param account: The account to update (from last event).
        """
        cdef str key_account = self.key_accounts + account.id.value

        self._redis.rpush(key_account, self._event_serializer.serialize(account.last_event))

    cpdef void delete_strategy(self, TradingStrategy strategy):
        """
        Deregister the given strategy with the execution client.

        :param strategy: The strategy to deregister.
        :raises ConditionFailed: If the strategy is not registered with the execution client.
        """
        pipe = self._redis.pipeline()
        pipe.delete(self.key_strategies + f'{strategy.id.value}:{CONFIG}')
        pipe.execute()

        self._log.debug(f"Deleted strategy (id={strategy.id.value}).")

    cdef set _decode_set_to_order_ids(self, set original):
        return {OrderId(element.decode(UTF8)) for element in original}

    cdef set _decode_set_to_position_ids(self, set original):
        return {PositionId(element.decode(UTF8)) for element in original}

    cdef set _decode_set_to_strategy_ids(self, set original):
        return {StrategyId.from_string(element.decode(UTF8)) for element in original}

# -- QUERIES --------------------------------------------------------------------------------------"

    cpdef set get_strategy_ids(self):
        """
        Return a list of all registered strategy identifiers.

        :return Set[StrategyId].
        """
        return  self._decode_set_to_strategy_ids(self._redis.keys(pattern=f'{self.key_strategies}*'))

    cpdef set get_order_ids(self, StrategyId strategy_id=None):
        """
        Return a list of all registered order identifiers.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Set[OrderId].
        """
        if strategy_id is None:
            return self._decode_set_to_order_ids(self._redis.smembers(name=self.key_index_orders))
        return self._decode_set_to_order_ids(self._redis.smembers(name=self.key_index_strategy_orders + strategy_id.value))

    cpdef set get_order_working_ids(self, StrategyId strategy_id=None):
        """
        Return a list of all registered order identifiers.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Set[OrderId].
        """
        if strategy_id is None:
            return self._decode_set_to_order_ids(self._redis.smembers(name=self.key_index_orders_working))
        return self._decode_set_to_order_ids(self._redis.sinter(keys=(self.key_index_orders_working, self.key_index_strategy_orders + strategy_id.value)))

    cpdef set get_order_completed_ids(self, StrategyId strategy_id=None):
        """
        Return a list of all registered order identifiers.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Set[OrderId].
        """
        if strategy_id is None:
            return self._decode_set_to_order_ids(self._redis.smembers(name=self.key_index_orders_completed))
        return self._decode_set_to_order_ids(self._redis.sinter(keys=(self.key_index_orders_completed, self.key_index_strategy_orders + strategy_id.value)))

    cpdef set get_position_ids(self, StrategyId strategy_id=None):
        """
        Return a list of the cached position identifiers.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Set[PositionId].
        """
        if strategy_id is None:
            return self._decode_set_to_position_ids(self._redis.smembers(name=self.key_index_positions))
        return self._decode_set_to_position_ids(self._redis.smembers(name=self.key_index_strategy_positions + strategy_id.value))

    cpdef set get_position_open_ids(self, StrategyId strategy_id=None):
        """
        Return a list of the cached position identifiers.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Set[PositionId].
        """
        if strategy_id is None:
            return self._decode_set_to_position_ids(self._redis.smembers(name=self.key_index_positions_open))
        return self._decode_set_to_position_ids(self._redis.sinter(keys=(self.key_index_positions_open, self.key_index_strategy_positions + strategy_id.value)))

    cpdef set get_position_closed_ids(self, StrategyId strategy_id=None):
        """
        Return a list of the cached position identifiers.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Set[PositionId].
        """
        if strategy_id is None:
            return self._decode_set_to_position_ids(self._redis.smembers(name=self.key_index_positions_closed))
        return self._decode_set_to_position_ids(self._redis.sinter(keys=(self.key_index_positions_closed, self.key_index_strategy_positions + strategy_id.value)))

    cpdef StrategyId get_strategy_for_order(self, OrderId order_id):
        """
        Return the strategy identifier associated with the given order identifier.

        :param order_id: The order identifier associated with the strategy.
        :return StrategyId or None:
        """
        return StrategyId.from_string(self._redis.hget(name=self.key_index_order_strategy, key=order_id.value).decode(UTF8))

    cpdef Order get_order(self, OrderId order_id):
        """
        Return the order matching the given identifier (if found).

        :return Order or None.
        """
        cdef Order order = self._cached_orders.get(order_id)
        if order is None:
            self._log_cannot_find_order(order_id)
        return order

    cpdef dict get_orders(self, StrategyId strategy_id=None):
        """
        Return all orders in the execution engines order book.

        :return Dict[OrderId, Order].
        """
        cdef set order_ids = self.get_order_ids(strategy_id)
        cdef dict orders

        try:
            orders = {order_id: self._cached_orders[order_id] for order_id in order_ids}
        except KeyError as ex:
            self._log.error("Cannot find order object in cached orders " + str(ex))

        return orders

    cpdef dict get_orders_working(self, StrategyId strategy_id=None):
        """
        Return all active orders in the execution engines order book.

        :return Dict[OrderId, Order].
        """
        cdef set order_ids = self.get_order_working_ids(strategy_id)
        cdef dict orders

        try:
            orders = {order_id: self._cached_orders[order_id] for order_id in order_ids}
        except KeyError as ex:
            self._log.error("Cannot find order object in cached orders " + str(ex))

        return orders

    cpdef dict get_orders_completed(self, StrategyId strategy_id=None):
        """
        Return all completed orders in the execution engines order book.

        :return Dict[OrderId, Order].
        """
        cdef set order_ids = self.get_order_completed_ids(strategy_id)
        cdef dict orders

        try:
            orders = {order_id: self._cached_orders[order_id] for order_id in order_ids}
        except KeyError as ex:
            self._log.error("Cannot find order object in cached orders " + str(ex))

        return orders

    cpdef Position get_position(self, PositionId position_id):
        """
        Return the position associated with the given position identifier (if found, else None).
        
        :param position_id: The position identifier.
        :return Position or None.
        """
        cdef Position position = self._cached_positions.get(position_id)
        if position is None:
            self._log_cannot_find_position(position_id)
        return position

    cpdef Position get_position_for_order(self, OrderId order_id):
        """
        Return the position associated with the given order identifier (if found, else None).
        
        :param order_id: The order identifier for the position.
        :return Position or None.
        """
        cdef PositionId position_id = self.get_position_id(order_id)
        if position_id is None:
            self._log.error(f"Cannot get position for {order_id} (no matching position id found).")
            return None

        return self._cached_positions.get(position_id)

    cpdef PositionId get_position_id(self, OrderId order_id):
        """
        Return the position associated with the given order identifier (if found, else None).
        
        :param order_id: The order identifier associated with the position.
        :return PositionId or None.
        """
        cdef PositionId position_id = PositionId(self._redis.hget(name=self.key_index_order_position, key=order_id.value).decode(UTF8))
        if position_id is None:
            self._log.error(f"Cannot get position id for {order_id} (no matching position id found).")

        return position_id

    cpdef dict get_positions(self, StrategyId strategy_id=None):
        """
        Return a list of all positions associated with the given strategy identifier.
        
        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Dict[PositionId, Position].
        """
        cdef set position_ids = self.get_position_ids(strategy_id)
        cdef dict positions

        try:
            positions = {position_id: self._cached_positions[position_id] for position_id in position_ids}
        except KeyError as ex:
            # This should never happen
            self._log.error("Cannot find position object in cached positions " + str(ex))

        return positions

    cpdef dict get_positions_open(self, StrategyId strategy_id=None):
        """
        Return a list of all active positions associated with the given strategy identifier.
        
        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Dict[PositionId, Position].
        """
        cdef set position_ids = self.get_position_open_ids(strategy_id)
        cdef dict positions

        try:
            positions = {position_id: self._cached_positions[position_id] for position_id in position_ids}
        except KeyError as ex:
            # This should never happen
            self._log.error("Cannot find position object in cached positions " + str(ex))

        return positions

    cpdef dict get_positions_closed(self, StrategyId strategy_id=None):
        """
        Return a dictionary of closed positions.
        
        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return Dict[PositionId, Position].
        """
        cdef set position_ids = self.get_position_closed_ids(strategy_id)
        cdef dict positions

        try:
            positions = {position_id: self._cached_positions[position_id] for position_id in position_ids}
        except KeyError as ex:
            # This should never happen
            self._log.error("Cannot find position object in cached positions " + str(ex))

        return positions

    cpdef bint order_exists(self, OrderId order_id):
        """
        Return a value indicating whether an order with the given identifier exists.
        
        :param order_id: The order identifier to check.
        :return True if the order exists, else False.
        """
        return self._redis.sismember(name=self.key_index_orders, value=order_id.value)

    cpdef bint is_order_working(self, OrderId order_id):
        """
        Return a value indicating whether an order with the given identifier is active.
         
        :param order_id: The order identifier to check.
        :return True if the order is found and active, else False.
        """
        return self._redis.sismember(name=self.key_index_orders_working, value=order_id.value)

    cpdef bint is_order_completed(self, OrderId order_id):
        """
        Return a value indicating whether an order with the given identifier is complete.

        :param order_id: The order identifier to check.
        :return True if the order is found and complete, else False.
        """
        return self._redis.sismember(name=self.key_index_orders_completed, value=order_id.value)

    cpdef bint position_exists(self, PositionId position_id):
        """
        Return a value indicating whether a position with the given identifier exists.
        :param position_id: The position identifier.
        :return True if the position exists, else False.
        """
        return self._redis.sismember(name=self.key_index_positions, value=position_id.value)

    cpdef bint position_exists_for_order(self, OrderId order_id):
        """
        Return a value indicating whether there is a position associated with the given
        order identifier.

        :param order_id: The order identifier.
        :return True if an associated position exists, else False.
        """
        cdef str position_id_str = self._redis.hget(name=self.key_index_order_position, key=order_id.value).decode(UTF8)
        if position_id_str is None:
            return False
        return self._redis.hget(name=self.key_index_positions + position_id_str, key=position_id_str)

    cpdef bint is_position_open(self, PositionId position_id):
        """
        Return a value indicating whether a position with the given identifier exists
        and is entered (active).

        :param position_id: The position identifier.
        :return True if the position exists and is exited, else False.
        """
        return self._redis.sismember(name=self.key_index_positions_open, value=position_id.value)

    cpdef bint is_position_closed(self, PositionId position_id):
        """
        Return a value indicating whether a position with the given identifier exists
        and is exited (closed).

        :param position_id: The position identifier.
        :return True if the position does not exist or is closed, else False.
        """
        return self._redis.sismember(name=self.key_index_positions_closed, value=position_id.value)

    cpdef int count_orders_total(self, StrategyId strategy_id=None):
        """
        Return the total count of positions held by the database.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return int.
        """
        if strategy_id is None:
            return self._redis.scard(self.key_index_orders)

        return len(self._redis.sinter(keys=(self.key_index_orders, self.key_index_strategy_orders + strategy_id.value)))

    cpdef int count_orders_working(self, StrategyId strategy_id=None):
        """
        Return the count of open positions held by the execution database.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return int.
        """
        if strategy_id is None:
            return self._redis.scard(self.key_index_orders_working)

        return len(self._redis.sinter(keys=(self.key_index_orders_working, self.key_index_strategy_orders + strategy_id.value)))

    cpdef int count_orders_completed(self, StrategyId strategy_id=None):
        """
        Return the count of closed positions held by the execution database.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return int.
        """
        if strategy_id is None:
            return self._redis.scard(self.key_index_orders_completed)

        return len(self._redis.sinter(keys=(self.key_index_orders_completed, self.key_index_strategy_orders + strategy_id.value)))

    cpdef int count_positions_total(self, StrategyId strategy_id=None):
        """
        Return the total count of positions held by the database.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return int.
        """
        if strategy_id is None:
            return self._redis.scard(self.key_index_positions)

        return len(self._redis.sinter(keys=(self.key_index_positions, self.key_index_strategy_positions + strategy_id.value)))

    cpdef int count_positions_open(self, StrategyId strategy_id=None):
        """
        Return the count of open positions held by the execution database.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return int.
        """
        if strategy_id is None:
            return self._redis.scard(self.key_index_positions_open)

        return len(self._redis.sinter(keys=(self.key_index_positions_open, self.key_index_strategy_positions + strategy_id.value)))

    cpdef int count_positions_closed(self, StrategyId strategy_id=None):
        """
        Return the count of closed positions held by the execution database.

        :param strategy_id: The strategy identifier query filter (optional can be None).
        :return int.
        """
        if strategy_id is None:
            return self._redis.scard(self.key_index_positions_closed)

        return len(self._redis.sinter(keys=(self.key_index_positions_closed, self.key_index_strategy_positions + strategy_id.value)))


cdef class LiveExecutionEngine(ExecutionEngine):
    """
    Provides a process and thread safe execution engine utilizing Redis.
    """

    def __init__(self,
                 ExecutionDatabase database,
                 Account account,
                 Portfolio portfolio,
                 Clock clock,
                 GuidFactory guid_factory,
                 Logger logger):
        """
        Initializes a new instance of the RedisExecutionEngine class.

        :param database: The execution database for the engine.
        :param account: The account for the engine.
        :param portfolio: The portfolio for the engine.
        :param clock: The clock for the engine.
        :param guid_factory: The guid factory for the engine.
        :param logger: The logger for the engine.
        """
        super().__init__(
            database=database,
            account=account,
            portfolio=portfolio,
            clock=clock,
            guid_factory=guid_factory,
            logger=logger)

        self._queue = queue.Queue()
        self._thread = threading.Thread(target=self._process_queue, daemon=True)
        self._thread.start()

    cpdef void execute_command(self, Command command):
        """
        Execute the given command by inserting it into the message bus for processing.
        
        :param command: The command to execute.
        """
        self._queue.put(command)

    cpdef void handle_event(self, Event event):
        """
        Handle the given event by inserting it into the message bus for processing.
        
        :param event: The event to handle
        """
        self._queue.put(event)

    cpdef void _process_queue(self):
        self._log.info("Running...")

        # Process the queue one item at a time
        cdef Message message
        while True:
            message = self._queue.get()

            if message.message_type == MessageType.EVENT:
                self._handle_event(message)
            elif message.message_type == MessageType.COMMAND:
                self._execute_command(message)
            else:
                raise RuntimeError(f"Invalid message type on queue ({repr(message)}).")


cdef class LiveExecClient(ExecutionClient):
    """
    Provides an execution client for live trading utilizing a ZMQ transport
    to the execution service.
    """

    def __init__(
            self,
            ExecutionEngine exec_engine,
            zmq_context: Context,
            str service_name='NautilusExecutor',
            str service_address='localhost',
            str events_topic='NAUTILUS:EVENTS',
            int commands_port=55555,
            int events_port=55556,
            CommandSerializer command_serializer=MsgPackCommandSerializer(),
            ResponseSerializer response_serializer=MsgPackResponseSerializer(),
            EventSerializer event_serializer=MsgPackEventSerializer(),
            Logger logger=LiveLogger()):
        """
        Initializes a new instance of the LiveExecClient class.

        :param exec_engine: The execution engine for the component.
        :param zmq_context: The ZMQ context.
        :param service_name: The name of the service.
        :param service_address: The execution service host IP address (default='localhost').
        :param events_topic: The execution service events topic (default='NAUTILUS:EXECUTION').
        :param commands_port: The execution service commands port (default=55555).
        :param events_port: The execution service events port (default=55556).
        :param command_serializer: The command serializer for the client.
        :param response_serializer: The response serializer for the client.
        :param event_serializer: The event serializer for the client.

        :param logger: The logger for the component (can be None).
        :raises ConditionFailed: If the service_address is not a valid string.
        :raises ConditionFailed: If the events_topic is not a valid string.
        :raises ConditionFailed: If the commands_port is not in range [0, 65535].
        :raises ConditionFailed: If the events_port is not in range [0, 65535].
        """
        Condition.valid_string(service_address, 'service_address')
        Condition.valid_string(events_topic, 'events_topic')
        Condition.in_range(commands_port, 'commands_port', 0, 65535)
        Condition.in_range(events_port, 'events_port', 0, 65535)

        super().__init__(exec_engine, logger)
        self._zmq_context = zmq_context

        self._commands_worker = RequestWorker(
            f'{self.__class__.__name__}.CommandRequester',
            f'{service_name}.CommandRouter',
            service_address,
            commands_port,
            self._zmq_context,
            logger)

        self._events_worker = SubscriberWorker(
            f'{self.__class__.__name__}.EventSubscriber',
            f'{service_name}.EventPublisher',
            service_address,
            events_port,
            self._zmq_context,
            self._event_handler,
            logger)

        self._command_serializer = command_serializer
        self._response_serializer = response_serializer
        self._event_serializer = event_serializer

        self.events_topic = events_topic

    cpdef void connect(self):
        """
        Connect to the execution service.
        """
        self._events_worker.connect()
        self._commands_worker.connect()
        self._events_worker.subscribe(self.events_topic)

    cpdef void disconnect(self):
        """
        Disconnect from the execution service.
        """
        self._events_worker.unsubscribe(self.events_topic)
        self._commands_worker.disconnect()
        self._events_worker.disconnect()

    cpdef void dispose(self):
        """
        Disposes of the execution client.
        """
        self._commands_worker.dispose()
        self._events_worker.dispose()

    cpdef void reset(self):
        """
        Reset the execution client.
        """
        self._reset()

    cpdef void account_inquiry(self, AccountInquiry command):
        self._command_handler(command)

    cpdef void submit_order(self, SubmitOrder command):
        self._command_handler(command)

    cpdef void submit_atomic_order(self, SubmitAtomicOrder command):
        self._command_handler(command)

    cpdef void modify_order(self, ModifyOrder command):
        self._command_handler(command)

    cpdef void cancel_order(self, CancelOrder command):
        self._command_handler(command)

    cdef void _command_handler(self, Command command):
        self._log.debug(f"Sending {command} ...")
        cdef bytes response_bytes = self._commands_worker.send(self._command_serializer.serialize(command))
        cdef Response response =  self._response_serializer.deserialize(response_bytes)
        self._log.debug(f"Received response {response}")

    cdef void _event_handler(self, str topic, bytes event_bytes):
        cdef Event event = self._event_serializer.deserialize(event_bytes)
        self._exec_engine.handle_event(event)
