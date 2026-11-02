"""Actual native add-items/receipt transactions through Auth and PostgREST.

Called with a real authenticated manager, an existing owned order and menu.
No browser, physical-device, full-plan or long-duration acceptance is inferred.
"""
from concurrent.futures import ThreadPoolExecutor
import json
import uuid

from owned_platform import private_json, literal


def run(platform, *, store, order, menu, manager, other_actor):
    def call(name, body, token=manager):
        status, value = platform.request('pos', '/rest/v1/rpc/' + name, body, token=token)
        if status != 200:
            private_json(platform.output / 'additional-order-recovery-failure.private.json',
                         {'rpc': name, 'status': status, 'body': value})
            raise RuntimeError('Actual additional-order recovery API failed: ' + name)
        return value

    operation = 'additional-' + str(uuid.uuid4())
    body = {'p_store_id': store, 'p_order_id': order,
            'p_items': [{'menu_item_id': menu, 'quantity': 1}],
            'p_client_mutation_id': operation}
    gateway = platform.gateways['pos']
    route = 'rest/rpc/add_order_items_once_v1'
    gateway.drop_next[route] = 1
    lost = False
    try:
        platform.request('pos', '/rest/v1/rpc/add_order_items_once_v1', body, token=manager)
    except OSError:
        lost = True
    finally:
        gateway.drop_next[route] = 0
    platform.check(lost, 'additional-order-native-commit-ack-physically-lost-' + store)
    with ThreadPoolExecutor(max_workers=2) as pool:
        recovered = list(pool.map(lambda _: call('add_order_items_once_v1', body), range(2)))
    ids = [[r['id'] for r in result] for result in recovered]
    platform.check(len(ids[0]) == 1 and ids[0] == ids[1], 'concurrent-add-retries-return-one-original-line-' + store)
    receipt_body = {'p_store_id': store, 'p_client_mutation_ids': [operation, operation, 'absent']}
    receipts = call('get_order_add_receipts_v1', receipt_body)
    platform.check(len(receipts) == 1 and receipts[0]['item_ids'] == ids[0], 'additional-order-batch-receipt-is-exact-original-' + store)
    platform.check(call('get_order_add_receipts_v1', receipt_body, other_actor) == [], 'another-actor-cannot-read-add-receipt-' + store)
    status, rejection = platform.request('pos', '/rest/v1/rpc/add_order_items_once_v1',
        {**body, 'p_items': [{'menu_item_id': menu, 'quantity': 9}]}, token=manager)
    platform.check(status == 400 and rejection.get('message') == 'ORDER_ADD_OPERATION_CONFLICT', 'add-original-payload-cannot-change-' + store)
    status, rejection = platform.request('pos', '/rest/v1/rpc/get_order_add_receipts_v1',
        {'p_store_id': store, 'p_client_mutation_ids': ['absent'] * 101}, token=manager)
    platform.check(status == 400 and rejection.get('message') == 'ORDER_ADD_RECEIPT_BATCH_INVALID', 'add-receipt-read-limit-is-enforced-' + store)
    status, rejection = platform.request('pos', '/rest/v1/rpc/add_order_items_once_v1',
        {**body, 'p_items': body['p_items'] * 501}, token=manager)
    platform.check(status == 400 and rejection.get('message') == 'ORDER_ITEMS_REQUIRED', 'add-write-line-limit-is-enforced-' + store)
    before = int(platform.sql('pos', 'SELECT count(*) FROM order_items WHERE order_id=' + literal(order) + ';').stdout.strip())
    unique = ['batch-add-' + str(uuid.uuid4()) for _ in range(2)]
    command = lambda op: {'kind': 'add', 'operation': op, 'params': {k: v for k, v in body.items() if k != 'p_client_mutation_id'}}
    commands = [command(unique[0]), command(unique[1]), command(unique[0])]
    batch = {'p_store_id': store, 'p_commands': commands}
    first = call('execute_order_command_batch_v1', batch)
    second = call('execute_order_command_batch_v1', batch)
    after = int(platform.sql('pos', 'SELECT count(*) FROM order_items WHERE order_id=' + literal(order) + ';').stdout.strip())
    platform.check(first == second and all(r['status'] == 'confirmed' for r in first) and after == before + 2,
                   'bounded-original-command-batch-and-retry-add-each-once-' + store)
    status, rejection = platform.request('pos', '/rest/v1/rpc/execute_order_command_batch_v1',
        {'p_store_id': store, 'p_commands': [commands[0]] * 21}, token=manager)
    platform.check(status == 400 and rejection.get('message') == 'ORDER_COMMAND_BATCH_INVALID', 'command-batch-size-limit-is-enforced-' + store)
    partial = call('execute_order_command_batch_v1', {'p_store_id': store, 'p_commands': [
        commands[0], {**commands[1], 'params': {**commands[1]['params'], 'p_items': [{'menu_item_id': menu, 'quantity': 5}]}}]})
    platform.check(partial[0]['status'] == 'confirmed' and partial[1]['status'] == 'rejected', 'batch-reject-preserves-other-confirmed-results-' + store)
