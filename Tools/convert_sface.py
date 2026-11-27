"""Convert OpenCV Zoo's SFace ONNX model (Apache-2.0) to Core ML.

Source: https://huggingface.co/opencv/face_recognition_sface
Needs: coremltools, onnx, numpy.
Usage: python -I convert_sface.py face_recognition_sface_2021dec.onnx FaceEmbedder.mlpackage
"""
import sys
import numpy as np
import onnx
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from onnx import numpy_helper

source, destination = sys.argv[1], sys.argv[2]
graph = onnx.load(source).graph
weights = {i.name: numpy_helper.to_array(i).astype(np.float32) for i in graph.initializer}


@mb.program(input_specs=[mb.TensorSpec(shape=(1, 3, 112, 112))], opset_version=ct.target.macOS14)
def program(data):
    values = {"data": data}
    for node in graph.node:
        attrs = {a.name: onnx.helper.get_attribute_value(a) for a in node.attribute}
        x = values[node.input[0]]
        name = node.output[0]
        if node.op_type == "Sub":
            out = mb.sub(x=x, y=weights[node.input[1]][0], name=name)
        elif node.op_type == "Mul":
            out = mb.mul(x=x, y=weights[node.input[1]][0], name=name)
        elif node.op_type == "Conv":
            pads = attrs["pads"]
            out = mb.conv(x=x, weight=weights[node.input[1]], strides=attrs["strides"],
                          dilations=attrs["dilations"], groups=attrs["group"], pad_type="custom",
                          pad=[pads[0], pads[2], pads[1], pads[3]], name=name)
        elif node.op_type == "BatchNormalization":
            gamma, beta, mean, var = (weights[n] for n in node.input[1:5])
            if len(x.shape) == 2:  # batch norm over a feature vector
                out = mb.add(x=mb.mul(x=mb.sub(x=x, y=mean), y=(gamma / np.sqrt(var + attrs["epsilon"]))),
                             y=beta, name=name)
            else:
                out = mb.batch_norm(x=x, mean=mean, variance=var, gamma=gamma, beta=beta,
                                    epsilon=attrs["epsilon"], name=name)
        elif node.op_type == "PRelu":
            out = mb.prelu(x=x, alpha=weights[node.input[1]].reshape(-1), name=name)
        elif node.op_type == "Dropout":
            out = x
        elif node.op_type == "Flatten":
            out = mb.flatten2d(x=x, axis=1, name=name)
        elif node.op_type == "Gemm":
            out = mb.linear(x=x, weight=weights[node.input[1]], bias=weights[node.input[2]], name=name)
        else:
            raise ValueError(node.op_type)
        values[node.output[0]] = out
    return mb.identity(x=values[graph.output[0].name], name="embedding")


model = ct.convert(program, convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                   minimum_deployment_target=ct.target.macOS14,
                   inputs=[ct.ImageType(name="data", shape=(1, 3, 112, 112), color_layout=ct.colorlayout.RGB)],
                   outputs=[ct.TensorType(name="embedding")])
model.short_description = "SFace face embedding (OpenCV Zoo, Apache-2.0)"
model.save(destination)

# Check the converted model against an independent NumPy forward pass of the ONNX weights.
# (onnx's ReferenceEvaluator is not used: it does not run this opset-11 BatchNormalization in inference mode.)
def numpy_forward(data):
    v = {"data": data}
    for node in graph.node:
        a = {i.name: onnx.helper.get_attribute_value(i) for i in node.attribute}
        x = v[node.input[0]]
        p = [weights[n] for n in node.input[1:] if n in weights]
        if node.op_type == "Sub":
            y = x - p[0]
        elif node.op_type == "Mul":
            y = x * p[0]
        elif node.op_type == "Conv":
            w, g, s = p[0], a["group"], a["strides"][0]
            pad = a["pads"][0]
            x = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)))
            win = np.lib.stride_tricks.sliding_window_view(x, w.shape[2:], axis=(2, 3))[:, :, ::s, ::s]
            ic, oc = x.shape[1] // g, w.shape[0] // g
            y = np.concatenate([np.einsum("nchwij,ocij->nohw", win[:, k * ic:(k + 1) * ic], w[k * oc:(k + 1) * oc],
                                          optimize=True) for k in range(g)], axis=1)
        elif node.op_type == "BatchNormalization":
            shape = (1, -1) + (1,) * (x.ndim - 2)
            gamma, beta, mean, var = (q.reshape(shape) for q in p)
            y = (x - mean) / np.sqrt(var + a["epsilon"]) * gamma + beta
        elif node.op_type == "PRelu":
            y = np.where(x > 0, x, x * p[0])
        elif node.op_type == "Dropout":
            y = x
        elif node.op_type == "Flatten":
            y = x.reshape(x.shape[0], -1)
        elif node.op_type == "Gemm":
            y = x @ p[0].T + p[1]
        v[node.output[0]] = y.astype(np.float32)
    return v[graph.output[0].name]


from PIL import Image
pixels = np.random.default_rng(0).integers(0, 256, (112, 112, 3), dtype=np.uint8)
expected = numpy_forward(pixels.transpose(2, 0, 1)[None].astype(np.float32))[0]
actual = model.predict({"data": Image.fromarray(pixels)})["embedding"][0]
cosine = float(np.dot(expected, actual) / (np.linalg.norm(expected) * np.linalg.norm(actual)))
print(f"embedding size {actual.size}, cosine vs ONNX weights {cosine:.6f}, max abs diff {np.abs(expected - actual).max():.5f}")
assert cosine > 0.999
