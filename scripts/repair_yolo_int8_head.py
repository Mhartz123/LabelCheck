"""Repair the YOLOv5nu INT8 export.

Bug: the final Concat merges box coords (range 0..640) with sigmoid class
scores (range 0..1), then a single per-tensor QuantizeLinear with
scale=2.537 / zp=0 is applied to the result. Anything below scale/2 = 1.268
rounds to bucket 0, so every class score dequantizes to exactly 0.0 and the
model can never detect anything.

Fix: drop the two tail Q/DQ pairs (the output0 pair, and the Mul_2 pair that
forced the coarse scale). Both sit after the last Conv, so removing them
costs no inference speed and no file size -- all 76 quantized Convs stay
quantized. Only the final concat now stays in float32.

Second bug, same export: onnxruntime.quant stamps the model with an
opset_import for every domain it knows -- com.microsoft, com.microsoft.nchwc,
com.microsoft.experimental, org.pytorch.aten, ai.onnx.training, ai.onnx.ml --
even though every node in the graph is plain ai.onnx. Desktop onnxruntime has
all of those registered and loads it happily; a mobile/reduced build does not,
and refuses the whole model at session creation ("model failed to load") with
no hint as to which domain it objected to. So prune the imports down to the
domains the nodes actually use.
"""
import sys, onnx

src, dst = sys.argv[1], sys.argv[2]
m = onnx.load(src)
g = m.graph

DROP = {"output0_QuantizeLinear", "output0_DequantizeLinear",
        "/model.24/Mul_2_output_0_QuantizeLinear",
        "/model.24/Mul_2_output_0_DequantizeLinear"}

# Map each dropped Q/DQ node's output -> its input, so consumers bypass it.
bypass = {}
for n in g.node:
    if n.name in DROP:
        bypass[n.output[0]] = n.input[0]

def resolve(name):
    seen = set()
    while name in bypass and name not in seen:
        seen.add(name)
        name = bypass[name]
    return name

keep = [n for n in g.node if n.name not in DROP]
for n in keep:
    for i, inp in enumerate(n.input):
        n.input[i] = resolve(inp)
    # Concat_3 previously fed output0_QuantizeLinear; make it the graph output.
    for i, out in enumerate(n.output):
        if out == "output0_QuantizeLinear_Input":
            n.output[i] = "output0"

del g.node[:]
g.node.extend(keep)

# Drop now-orphaned scale/zero-point initializers.
used = {i for n in g.node for i in n.input}
orphans = [i for i in g.initializer if i.name not in used]
for o in orphans:
    g.initializer.remove(o)

# Clear stale value_info for removed tensors.
del g.value_info[:]

# Keep only the opset imports the graph actually needs. Everything else is a
# load-time landmine on mobile.
used_domains = {n.domain or "" for n in g.node}
kept_opsets = [o for o in m.opset_import if (o.domain or "") in used_domains]
dropped = [o.domain for o in m.opset_import if (o.domain or "") not in used_domains]
del m.opset_import[:]
m.opset_import.extend(kept_opsets)

onnx.checker.check_model(m)
onnx.save(m, dst)
print(f"removed {len(DROP)} tail Q/DQ nodes, {len(orphans)} orphan initializers")
print(f"pruned opset imports: dropped {dropped or 'none'}; "
      f"kept {[(o.domain or 'ai.onnx', o.version) for o in kept_opsets]}")
print(f"nodes: {len(keep)}  ->  {dst}")
