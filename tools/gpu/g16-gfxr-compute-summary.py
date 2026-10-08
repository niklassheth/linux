#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Inspect gfxrecon-convert JSONL for compute/transfer submissions (no replay)."""
import argparse
import collections
import copy
import json
import math
import sys


DIRECT = {'vkCmdDispatch', 'vkCmdDispatchBase', 'vkCmdDispatchBaseKHR'}
SYNC = {'vkCmdPipelineBarrier', 'vkCmdPipelineBarrier2', 'vkCmdPipelineBarrier2KHR',
        'vkCmdWaitEvents', 'vkCmdWaitEvents2', 'vkCmdWaitEvents2KHR',
        'vkCmdSetEvent', 'vkCmdSetEvent2', 'vkCmdSetEvent2KHR', 'vkCmdResetEvent',
        'vkCmdBeginQuery', 'vkCmdEndQuery', 'vkCmdResetQueryPool',
        'vkCmdWriteTimestamp', 'vkCmdWriteTimestamp2', 'vkCmdWriteTimestamp2KHR'}
SUBMIT = {'vkQueueSubmit', 'vkQueueSubmit2', 'vkQueueSubmit2KHR'}
COPIES = {'vkCmdCopyImageToBuffer', 'vkCmdCopyImageToBuffer2',
          'vkCmdCopyImageToBuffer2KHR', 'vkCmdCopyQueryPoolResults',
          'vkCmdCopyBuffer', 'vkCmdCopyBuffer2', 'vkCmdCopyBuffer2KHR',
          'vkCmdCopyBufferToImage', 'vkCmdCopyBufferToImage2', 'vkCmdCopyBufferToImage2KHR',
          'vkCmdCopyImage', 'vkCmdCopyImage2', 'vkCmdCopyImage2KHR',
          'vkCmdBlitImage', 'vkCmdBlitImage2', 'vkCmdBlitImage2KHR',
          'vkCmdResolveImage', 'vkCmdResolveImage2', 'vkCmdResolveImage2KHR',
          'vkCmdClearColorImage', 'vkCmdClearDepthStencilImage',
          'vkCmdFillBuffer', 'vkCmdUpdateBuffer'}


def array(value):
    # gfxrecon emits one-element structure arrays as objects. Handles may
    # likewise be scalar; null is the empty pointer, not an array element.
    return [] if value is None else value if isinstance(value, list) else [value]


def compute(bind_point):
    return bind_point in (1, 'VK_PIPELINE_BIND_POINT_COMPUTE')


def state():
    return {'pipeline': None, 'descriptors': None, 'sync': [], 'commands': []}


def commands_of(submit):
    if 'pCommandBufferInfos' in submit:
        return [info['commandBuffer'] for info in array(submit['pCommandBufferInfos'])]
    return array(submit.get('pCommandBuffers'))


class Inspector:
    def __init__(self, limit):
        self.limit = limit
        self.counts = collections.Counter()
        self.buffers = {}
        self.pools = {}
        self.pipelines = {}
        self.patterns = {}
        self.unknown = collections.Counter()
        self.in_state = False
        self.state_counts = collections.Counter()
        self.frame_counts = collections.Counter()
        self.state_submit_count = 0
        self.submit_count = 0
        self.submitted_operations = 0

    def flatten(self, buffer, path=()):
        if buffer in path:
            self.unknown['secondary_cycle'] += 1
            return
        if buffer not in self.buffers:
            self.unknown['unobserved_command_buffer'] += 1
            return
        for command in self.buffers[buffer]['commands']:
            if 'secondary' in command:
                for child in command['secondary']:
                    yield from self.flatten(child, path + (buffer,))
            else:
                yield command

    def submit(self, index, function, args):
        self.submit_count += 1
        for batch_index, batch in enumerate(array(args.get('pSubmits'))):
            for buffer in commands_of(batch):
                for operation in self.flatten(buffer):
                    self.submitted_operations += 1
                    # Group repeated executions while preserving representative
                    # first/last submissions and the original recording index.
                    key = json.dumps({k: operation.get(k) for k in
                                      ('name', 'pipeline', 'dimensions', 'arguments')}, sort_keys=True)
                    if key not in self.patterns:
                        self.patterns[key] = {'operation': operation, 'executions': 0}
                    pattern = self.patterns[key]
                    pattern['executions'] += 1
                    submission = {'index': index, 'queue': args.get('queue'),
                                  'batch': batch_index, 'fence': args.get('fence'),
                                  'result': function.get('return'),
                                  'dependencies': {k: v for k, v in batch.items()
                                                   if k not in ('pCommandBuffers', 'pCommandBufferInfos')}}
                    pattern.setdefault('first_submission', submission)
                    pattern['last_submission'] = submission

    def feed(self, record):
        if 'state' in record:
            self.in_state = record['state'].get('marker_type') == 'BeginMarker'
            return
        function = record.get('function')
        if not function:
            return
        name = function['name']
        args = function.get('args') or {}
        index = record.get('index')
        self.counts[name] += 1
        (self.state_counts if self.in_state else self.frame_counts)[name] += 1
        if name == 'vkCreateComputePipelines':
            for pipeline, info in zip(array(args.get('pPipelines')), array(args.get('pCreateInfos'))):
                self.pipelines[pipeline] = copy.deepcopy(info)
        if name == 'vkAllocateCommandBuffers':
            pool = (args.get('pAllocateInfo') or {}).get('commandPool')
            for buffer in array(args.get('pCommandBuffers')):
                self.buffers[buffer] = state()
                self.pools[buffer] = pool
        if name == 'vkFreeCommandBuffers':
            for buffer in array(args.get('pCommandBuffers')):
                self.buffers.pop(buffer, None)
                self.pools.pop(buffer, None)
        if name in ('vkResetCommandPool', 'vkDestroyCommandPool'):
            for buffer, pool in list(self.pools.items()):
                if pool == args.get('commandPool'):
                    if name == 'vkDestroyCommandPool':
                        self.buffers.pop(buffer, None)
                        self.pools.pop(buffer, None)
                    else:
                        self.buffers[buffer] = state()
        if name in SUBMIT:
            # Keep reconstructed definitions, but don't count trim setup's
            # synthesized submissions as executions by the captured frames.
            if self.in_state:
                self.state_submit_count += 1
            else:
                self.submit(index, function, args)
            return
        buffer = args.get('commandBuffer')
        if buffer is None:
            return
        if name in ('vkBeginCommandBuffer', 'vkResetCommandBuffer'):
            self.buffers[buffer] = state()
        current = self.buffers.setdefault(buffer, state())
        arguments = {k: v for k, v in args.items() if k != 'commandBuffer'}
        if name == 'vkCmdBindPipeline' and compute(args.get('pipelineBindPoint')):
            current['pipeline'] = args.get('pipeline')
        elif name == 'vkCmdBindDescriptorSets' and compute(args.get('pipelineBindPoint')):
            current['descriptors'] = arguments
        elif name in SYNC:
            current['sync'].append({'index': index, 'name': name, 'arguments': arguments})
            del current['sync'][:-4]
        elif name == 'vkCmdExecuteCommands':
            current['commands'].append({'secondary': array(args.get('pCommandBuffers'))})
        elif name in DIRECT or name.startswith('vkCmdDispatchIndirect') or name in COPIES:
            operation = {'index': index, 'command_buffer': buffer, 'name': name,
                         'arguments': arguments, 'preceding_sync_last_four': list(current['sync'])}
            if name in DIRECT or name.startswith('vkCmdDispatchIndirect'):
                operation.update(pipeline=current['pipeline'], descriptors=current['descriptors'],
                                 pipeline_create_info=self.pipelines.get(current['pipeline']))
                if name in DIRECT:
                    dimensions = [args.get('groupCount' + axis) for axis in 'XYZ']
                    operation['dimensions'] = dimensions
                    operation['workgroups'] = math.prod(dimensions)
                else:
                    operation['workgroups'] = None
                    self.unknown['indirect_dimensions_require_buffer_contents'] += 1
            current['commands'].append(operation)

    def result(self):
        patterns = list(self.patterns.values())
        direct = [p for p in patterns if p['operation']['name'] in DIRECT]
        direct.sort(key=lambda p: p['operation']['workgroups'], reverse=True)
        indirect = [p for p in patterns if p['operation']['name'].startswith('vkCmdDispatchIndirect')]
        copies = [p for p in patterns if p['operation']['name'] in COPIES]
        return {'api_counts': dict(self.counts),
                'state_reconstruction_api_counts': dict(self.state_counts),
                'captured_frame_api_counts': dict(self.frame_counts),
                'state_reconstruction_submit_calls': self.state_submit_count,
                'queue_submit_calls': self.submit_count,
                'submitted_compute_or_transfer_operations': self.submitted_operations,
                'distinct_patterns': len(patterns), 'unknowns': dict(self.unknown),
                'largest_direct_dispatches_by_workgroups': direct[:self.limit],
                'indirect_dispatch_samples': indirect[:self.limit],
                'copy_and_query_resolve_samples': copies[:self.limit],
                'limits': ['Workgroup count is not GPU duration.',
                           'Indirect sizes require buffer contents at execution.',
                           'API waits are recorded, not proven satisfied.',
                           'Transfers may invoke driver-internal compute.',
                           'Deferred-trim initialization may contain synthesized setup calls.',
                           'Only four preceding sync commands are retained per operation.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--limit', type=int, default=30)
    parser.add_argument('jsonl', nargs='?', default='-')
    args = parser.parse_args()
    inspector = Inspector(args.limit)
    source = sys.stdin if args.jsonl == '-' else open(args.jsonl)
    try:
        for line in source:
            if line.strip():
                inspector.feed(json.loads(line))
    finally:
        if source is not sys.stdin:
            source.close()
    print(json.dumps(inspector.result(), indent=2))


if __name__ == '__main__':
    main()
