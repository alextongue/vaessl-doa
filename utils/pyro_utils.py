import torch
import gc
import collections
import resource
import os

def debug_memory():
    print('maxrss = {}'.format(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss))
    tensors = collections.Counter((str(o.device), o.dtype, tuple(o.shape))
                                  for o in gc.get_objects()
                                  if torch.is_tensor(o))
    for line in sorted(tensors.items()):
        print('{}\t{}'.format(*line))

def show_mem_percent():
    # Getting all memory using os.popen()
    total_memory, used_memory, free_memory = map(
        int, os.popen('free -t -m').readlines()[-1].split()[1:])
  
    # Memory usage
    print("RAM memory % used:", round((used_memory/total_memory) * 100, 2))