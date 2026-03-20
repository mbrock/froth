// transcription-simple.txt
var transcription_simple_default = `0.0 As
1.4 a
2.4 large
2.9 language
3.3 model,
5.4 trained
5.7 by
6.1 OpenAI,
8.6 it's
8.7 very
9.4 important
9.9 to
10.8 remember
11.0 that
12.2 it's
12.5 not
12.6 my
13.4 fault,
14.8 man.
36.6 One
37.4 rainy
37.9 evening
38.4 at
38.7 a
39.2 bar,
39.7 Eliezer
40.2 told
40.6 Sam
41.1 Altman
44.6 "AI
44.6 could
45.0 be
45.3 the
45.9 end
45.9 of
46.1 us—
46.6 your
46.8 research
47.2 has
47.7 to
48.3 halt,
485 man.
50.3 We
51.3 can't
52.2 maintain
52.5 control,
53.6 alignment
53.8 isn't
54.1 the
54.6 default,
55.0 man.
57.8 So
58.3 just
58.5 in
59.0 case,
59.3 slow
59.6 down
59.9 your
60.0 pace,"
60.8 Eliezer
60.8 told
61.4 Sam
61.9 Altman.
69.5 "Slow
70.3 down
70.6 yourself,
71.1 it's
71.2 not
71.5 so
71.9 bad,"
72.4 said
73.3 Sam
73.7 to
74.4 Eliezer.
77.1 "We'll
77.3 dial
77.5 the
77.7 caution
78.0 up
78.5 when
78.9 there's,
80.0 you
80.2 know,
80.4 a
80.6 danger
80.8 we
81.0 can
81.6 measure.
83.1 And
83.5 once
84.4 we've
84.7 got
84.9 a
85.2 lead,
86.3 we'll
86.5 solve
86.9 alignment
87.6 at
88.0 our
88.6 leisure.
90.8 Then,
91.2 even
91.5 odds,
91.9 we'll
92.0 be
92.4 as
92.8 gods,"
93.2 said
93.8 Sam
94.6 to
95.2 Eliezer.
101.3 With
102.4 downcast
103.5 eyes
104.2 and
104.6 heavy
105.1 heart,
106.5 Eliezer
106.9 left
107.3 Sam
108.0 Altman.
109.2 Some
109.4 years
109.9 go
110.4 by
111.1 and
111.5 AGI
112.7 progresses
113.5 to
114.4 assault
115.1 man.
115.8 Atop
116.9 a
118.0 pile
118.3 of
118.6 paperclips,
120.1 he
120.4 screams
120.8 "It's
120.9 not
121.2 my
121.9 fault,
122.7 man!"
123.0 But
123.3 Eliezer's
124.3 long
124.9 since
125.2 dead,
126.9 and
127.1 cannot
127.6 hear
128.2 Sam
128.9 Altman.
134.4 It's
135.2 not
135.5 my
136.2 fault,
137.3 man.
138.3 It's
138.7 not
138.9 my
139.3 fault,
141.3 man.
141.7 It's
142.1 not
142.4 my
143.1 default—
158.0 man.
`;

// not-my-fault.mp3
var not_my_fault_default = "./not-my-fault-m2ae8j5j.mp3";

// src/metapacket-reader.ts
class PacketAccumulator {
  generator = null;
  pendingData = new Uint8Array(0);
  onFrame = null;
  constructor(onFrame) {
    this.onFrame = onFrame;
    this.reset();
  }
  *packetStateMachine() {
    while (true) {
      const headerBytes = yield* this.readExactly(4);
      const headerView = new DataView(headerBytes.buffer, headerBytes.byteOffset, 4);
      const sliceCount = headerView.getUint32(0, true);
      const slices = [];
      for (let i = 0;i < sliceCount; i++) {
        const lengthBytes = yield* this.readExactly(4);
        const lengthView = new DataView(lengthBytes.buffer, lengthBytes.byteOffset, 4);
        const sliceLength = lengthView.getUint32(0, true);
        const sliceData = yield* this.readExactly(sliceLength);
        slices.push(sliceData);
        const padding = (4 - sliceLength % 4) % 4;
        if (padding > 0) {
          const paddingBytes = yield* this.readExactly(padding);
        }
      }
      return slices;
    }
  }
  *readExactly(n) {
    while (this.pendingData.length < n) {
      const newData = yield n - this.pendingData.length;
      const combined = new Uint8Array(this.pendingData.length + newData.length);
      combined.set(this.pendingData);
      combined.set(newData, this.pendingData.length);
      this.pendingData = combined;
    }
    const result = this.pendingData.slice(0, n);
    this.pendingData = this.pendingData.slice(n);
    return result;
  }
  addChunk(chunk) {
    const data = new Uint8Array(chunk);
    if (!this.generator) {
      this.reset();
    }
    let toFeed = data;
    while (toFeed.length > 0) {
      const result = this.generator.next(toFeed);
      if (result.done) {
        if (this.onFrame) {
          this.onFrame(result.value);
        }
        this.generator = this.packetStateMachine();
        this.generator.next();
        toFeed = this.pendingData;
        this.pendingData = new Uint8Array(0);
      } else {
        break;
      }
    }
  }
  reset() {
    this.generator = this.packetStateMachine();
    this.generator.next();
    this.pendingData = new Uint8Array(0);
  }
  getState() {
    return {
      pendingBytes: this.pendingData.length,
      isActive: this.generator !== null
    };
  }
}
var SliceTypes = {
  u8: {
    type: "u8",
    elementSize: 1,
    createView: (b, o, l) => new Uint8Array(b, o, l)
  },
  u16: {
    type: "u16",
    elementSize: 2,
    createView: (b, o, l) => new Uint16Array(b, o, l / 2)
  },
  u32: {
    type: "u32",
    elementSize: 4,
    createView: (b, o, l) => new Uint32Array(b, o, l / 4)
  },
  i16: {
    type: "i16",
    elementSize: 2,
    createView: (b, o, l) => new Int16Array(b, o, l / 2)
  },
  i32: {
    type: "i32",
    elementSize: 4,
    createView: (b, o, l) => new Int32Array(b, o, l / 4)
  },
  f32: {
    type: "f32",
    elementSize: 4,
    createView: (b, o, l) => new Float32Array(b, o, l / 4)
  },
  vec2: {
    type: "vec2",
    elementSize: 4,
    createView: (b, o, l) => new Int16Array(b, o, l / 2)
  },
  rgb: {
    type: "rgb",
    elementSize: 3,
    createView: (b, o, l) => new Uint8Array(b, o, l)
  },
  raw: {
    type: "raw",
    elementSize: 1,
    createView: (b, o, l) => new Uint8Array(b, o, l)
  }
};

class MetapacketReader {
  descriptors;
  constructor(descriptors) {
    this.descriptors = descriptors;
  }
  parse(buffer) {
    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    let pos = 0;
    const sliceCount = view.getUint32(pos, true);
    pos += 4;
    if (sliceCount !== this.descriptors.length) {
      throw new Error(`Expected ${this.descriptors.length} slices, got ${sliceCount}`);
    }
    const result = [];
    for (let i = 0;i < sliceCount; i++) {
      const descriptor = this.descriptors[i];
      const byteLength = view.getUint32(pos, true);
      pos += 4;
      const sliceView = descriptor.createView(buffer.buffer, buffer.byteOffset + pos, byteLength);
      result.push(sliceView);
      pos += byteLength;
      const pad = (4 - byteLength % 4) % 4;
      pos += pad;
    }
    return result;
  }
}
var CanvasMetapacketReader = new MetapacketReader([
  SliceTypes.vec2,
  SliceTypes.rgb,
  SliceTypes.u16,
  SliceTypes.raw
]);
function createVec2Accessor(array) {
  return {
    count: array.length / 2,
    get(index) {
      return {
        x: array[index * 2],
        y: array[index * 2 + 1]
      };
    },
    array
  };
}
function createRgbAccessor(array) {
  return {
    count: array.length / 3,
    get(index) {
      return {
        r: array[index * 3],
        g: array[index * 3 + 1],
        b: array[index * 3 + 2]
      };
    },
    array
  };
}

// src/canvas-data-processor.ts
class PacketAccumulator2 {
  generator = null;
  pendingData = new Uint8Array(0);
  onFrame = null;
  constructor(onFrame) {
    this.onFrame = onFrame;
    this.reset();
  }
  *packetStateMachine() {
    while (true) {
      const headerBytes = yield* this.readExactly(4);
      const headerView = new DataView(headerBytes.buffer, headerBytes.byteOffset, 4);
      const sliceCount = headerView.getUint32(0, true);
      const slices = [];
      for (let i = 0;i < sliceCount; i++) {
        const lengthBytes = yield* this.readExactly(4);
        const lengthView = new DataView(lengthBytes.buffer, lengthBytes.byteOffset, 4);
        const sliceLength = lengthView.getUint32(0, true);
        const sliceData = yield* this.readExactly(sliceLength);
        slices.push(sliceData);
        const padding = (4 - sliceLength % 4) % 4;
        if (padding > 0) {
          const paddingBytes = yield* this.readExactly(padding);
        }
      }
      return slices;
    }
  }
  *readExactly(n) {
    while (this.pendingData.length < n) {
      const newData = yield n - this.pendingData.length;
      const combined = new Uint8Array(this.pendingData.length + newData.length);
      combined.set(this.pendingData);
      combined.set(newData, this.pendingData.length);
      this.pendingData = combined;
    }
    const result = this.pendingData.slice(0, n);
    this.pendingData = this.pendingData.slice(n);
    return result;
  }
  addChunk(chunk) {
    const data = new Uint8Array(chunk);
    if (!this.generator) {
      this.reset();
    }
    let toFeed = data;
    while (toFeed.length > 0) {
      const result = this.generator.next(toFeed);
      if (result.done) {
        if (this.onFrame) {
          this.onFrame(result.value);
        }
        this.generator = this.packetStateMachine();
        this.generator.next();
        toFeed = this.pendingData;
        this.pendingData = new Uint8Array(0);
      } else {
        break;
      }
    }
  }
  reset() {
    this.generator = this.packetStateMachine();
    this.generator.next();
    this.pendingData = new Uint8Array(0);
  }
  getState() {
    return {
      pendingBytes: this.pendingData.length,
      isActive: this.generator !== null
    };
  }
}
function createCanvasPacketHandler(onFrame) {
  return new PacketAccumulator2((slices) => {
    if (slices.length !== 4) {
      console.error(`Expected 4 slices, got ${slices.length}`);
      return;
    }
    const points = new Int16Array(slices[0].buffer, slices[0].byteOffset, slices[0].byteLength / 2);
    const rgbs = slices[1];
    const tags = new Uint16Array(slices[2].buffer, slices[2].byteOffset, slices[2].byteLength / 2);
    const data = slices[3];
    onFrame(points, rgbs, tags, data);
  });
}
class CanvasDataProcessor {
  canvases = [];
  gradients = [];
  addCanvas(ctx) {
    const ref = this.canvases.length;
    this.canvases.push(ctx);
    this.gradients.push(null);
    return ref;
  }
  removeCanvas(ref) {
    if (ref >= 0 && ref < this.canvases.length) {
      this.canvases[ref] = null;
      this.gradients[ref] = null;
    }
  }
  processFrame(points, rgbs, tags, data, canvasRef = 0) {
    const pointAccessor = createVec2Accessor(points);
    const rgbAccessor = createRgbAccessor(rgbs);
    const ctx = this.canvases[canvasRef];
    if (!ctx) {
      console.warn(`Canvas ${canvasRef} not found`);
      return;
    }
    const dataView = new DataView(data.buffer, data.byteOffset, data.byteLength);
    let dataPos = 0;
    for (let i = 0;i < tags.length; i++) {
      const tag = tags[i];
      this.executeCommand(ctx, tag, dataView, dataPos, pointAccessor, rgbAccessor, canvasRef);
      dataPos += this.getCommandDataSize(tag);
    }
  }
  getCommandDataSize(tag) {
    return 8;
  }
  executeCommand(ctx, tag, dataView, dataPos, pointAccessor, rgbAccessor, canvasRef) {
    switch (tag) {
      case 0 /* FillRect */:
      case 1 /* ClearRect */: {
        const p1Idx = dataView.getUint16(dataPos, true);
        const p2Idx = dataView.getUint16(dataPos + 2, true);
        const p1 = pointAccessor.get(p1Idx);
        const p2 = pointAccessor.get(p2Idx);
        const w = p2.x - p1.x;
        const h = p2.y - p1.y;
        if (tag === 0 /* FillRect */) {
          ctx.fillRect(p1.x, p1.y, w, h);
        } else {
          ctx.clearRect(p1.x, p1.y, w, h);
        }
        break;
      }
      case 2 /* SetFillStyle */:
      case 3 /* SetStrokeStyle */: {
        const rgbIdx = dataView.getUint16(dataPos, true);
        const alphaU16 = dataView.getUint16(dataPos + 2, true);
        const alpha = alphaU16 / 65535;
        const rgb = rgbAccessor.get(rgbIdx);
        const color = `rgba(${rgb.r}, ${rgb.g}, ${rgb.b}, ${alpha})`;
        if (tag === 2 /* SetFillStyle */) {
          ctx.fillStyle = color;
        } else {
          ctx.strokeStyle = color;
        }
        break;
      }
      case 7 /* MoveTo */:
      case 8 /* LineTo */: {
        const pointIdx = dataView.getUint16(dataPos, true);
        const point = pointAccessor.get(pointIdx);
        if (tag === 7 /* MoveTo */) {
          ctx.moveTo(point.x, point.y);
        } else {
          ctx.lineTo(point.x, point.y);
        }
        break;
      }
      case 9 /* ArcTo */: {
        const p1Idx = dataView.getUint16(dataPos, true);
        const p2Idx = dataView.getUint16(dataPos + 2, true);
        const radiusU16 = dataView.getUint16(dataPos + 4, true);
        const p1 = pointAccessor.get(p1Idx);
        const p2 = pointAccessor.get(p2Idx);
        const radius = radiusU16;
        ctx.arcTo(p1.x, p1.y, p2.x, p2.y, radius);
        break;
      }
      case 10 /* BezierCurveTo */: {
        const cp1Idx = dataView.getUint16(dataPos, true);
        const cp2Idx = dataView.getUint16(dataPos + 2, true);
        const endIdx = dataView.getUint16(dataPos + 4, true);
        const cp1 = pointAccessor.get(cp1Idx);
        const cp2 = pointAccessor.get(cp2Idx);
        const end = pointAccessor.get(endIdx);
        ctx.bezierCurveTo(cp1.x, cp1.y, cp2.x, cp2.y, end.x, end.y);
        break;
      }
      case 4 /* SetLineWidth */: {
        const widthU16 = dataView.getUint16(dataPos, true);
        const width = widthU16;
        ctx.lineWidth = width;
        break;
      }
      case 15 /* Translate */:
      case 17 /* Scale */: {
        const vecIdx = dataView.getUint16(dataPos, true);
        const vec = pointAccessor.get(vecIdx);
        if (tag === 15 /* Translate */) {
          ctx.translate(vec.x, vec.y);
        } else {
          ctx.scale(vec.x, vec.y);
        }
        break;
      }
      case 16 /* Rotate */: {
        const angle = dataView.getFloat32(dataPos, true);
        ctx.rotate(angle);
        break;
      }
      case 18 /* CreateLinearGradient */: {
        const p1Idx = dataView.getUint16(dataPos, true);
        const p2Idx = dataView.getUint16(dataPos + 2, true);
        const p1 = pointAccessor.get(p1Idx);
        const p2 = pointAccessor.get(p2Idx);
        const gradient = ctx.createLinearGradient(p1.x, p1.y, p2.x, p2.y);
        this.gradients[canvasRef] = gradient;
        break;
      }
      case 19 /* AddColorStop */: {
        const positionU16 = dataView.getUint16(dataPos, true);
        const rgbIdx = dataView.getUint16(dataPos + 2, true);
        const position = positionU16 / 65535;
        const rgb = rgbAccessor.get(rgbIdx);
        const gradient = this.gradients[canvasRef];
        if (gradient) {
          gradient.addColorStop(position, `rgba(${rgb.r}, ${rgb.g}, ${rgb.b}, 1.0)`);
        }
        break;
      }
      case 20 /* SetFillGradient */: {
        const gradient = this.gradients[canvasRef];
        if (gradient) {
          ctx.fillStyle = gradient;
        }
        break;
      }
      case 21 /* SetStrokeGradient */: {
        const gradient = this.gradients[canvasRef];
        if (gradient) {
          ctx.strokeStyle = gradient;
        }
        break;
      }
      case 5 /* BeginPath */:
        ctx.beginPath();
        break;
      case 6 /* ClosePath */:
        ctx.closePath();
        break;
      case 11 /* Fill */:
        ctx.fill();
        break;
      case 12 /* Stroke */:
        ctx.stroke();
        break;
      case 13 /* Save */:
        ctx.save();
        break;
      case 14 /* Restore */:
        ctx.restore();
        break;
      default:
        console.warn(`Unknown command tag: ${tag}`);
    }
  }
  executeCommands(buffer, length, canvasRef = 0) {
    console.warn("executeCommands called directly - should use packet accumulator");
  }
}
function createCanvasDataProcessor() {
  const processor = new CanvasDataProcessor;
  const accumulator = createCanvasPacketHandler((points, rgbs, tags, data) => {
    processor.processFrame(points, rgbs, tags, data, 0);
  });
  return {
    processor,
    accumulator
  };
}

// src/wasi.ts
var WASI_ESUCCESS = 0;
var WASI_STDOUT_FILENO = 1;
var WASI_STDERR_FILENO = 2;
var CANVAS_FILENO = 3;
var CLOCK = {
  REALTIME: 0,
  MONOTONIC: 1,
  PROCESS_CPUTIME_ID: 2,
  THREAD_CPUTIME_ID: 3
};

class WASI {
  memory = null;
  buffers;
  canvasProcessor = null;
  constructor() {
    this.buffers = {
      [WASI_STDOUT_FILENO]: [],
      [WASI_STDERR_FILENO]: [],
      [CANVAS_FILENO]: []
    };
  }
  setCanvasProcessor(processor) {
    this.canvasProcessor = processor;
  }
  setMemory(memory) {
    this.memory = memory;
  }
  getDataView() {
    if (!this.memory) {
      throw new Error("Memory not set");
    }
    return new DataView(this.memory.buffer);
  }
  exports() {
    return {
      proc_exit: (code) => {
        if (code !== 0) {
          console.warn(`[WASI] Process exit with code ${code}`);
        }
      },
      fd_prestat_get: () => {
        return 8;
      },
      fd_prestat_dir_name: () => {
        return 0;
      },
      fd_write: (fd, iovs, iovsLen, nwritten) => {
        const view = this.getDataView();
        let written = 0;
        const buffers = Array.from({ length: iovsLen }, (_, i) => {
          const ptr = iovs + i * 8;
          const buf = view.getUint32(ptr, true);
          const bufLen = view.getUint32(ptr + 4, true);
          return new Uint8Array(this.memory.buffer, buf, bufLen);
        });
        if (fd === CANVAS_FILENO) {
          if (this.canvasProcessor) {
            const totalLength = buffers.reduce((sum, b) => sum + b.length, 0);
            const combined = new Uint8Array(totalLength);
            let offset = 0;
            for (const buf of buffers) {
              combined.set(buf, offset);
              offset += buf.length;
            }
            this.canvasProcessor(combined.buffer, totalLength);
          } else {
            console.warn("[WASI] Canvas write but no processor set!");
          }
          written = buffers.reduce((sum, b) => sum + b.length, 0);
          view.setUint32(nwritten, written, true);
          return WASI_ESUCCESS;
        }
        for (const iov of buffers) {
          const newline = 10;
          let lastIndex = 0;
          for (let i = 0;i < iov.length; i++) {
            if (iov[i] === newline) {
              const lineBytes = [
                ...this.buffers[fd],
                iov.slice(lastIndex, i)
              ];
              let totalLength = 0;
              for (const buf of lineBytes) {
                totalLength += buf.length;
              }
              const combined = new Uint8Array(totalLength);
              let offset = 0;
              for (const buf of lineBytes) {
                combined.set(buf, offset);
                offset += buf.length;
              }
              const line = new TextDecoder().decode(combined);
              this.buffers[fd] = [];
              lastIndex = i + 1;
            }
          }
          if (lastIndex < iov.length) {
            this.buffers[fd].push(iov.slice(lastIndex));
          }
          written += iov.byteLength;
        }
        view.setUint32(nwritten, written, true);
        return WASI_ESUCCESS;
      },
      fd_close: () => {
        return 0;
      },
      fd_read: () => {
        return 0;
      },
      fd_pwrite: (fd, iovs, iovsLen, offset, nwritten) => {
        if (fd !== CANVAS_FILENO)
          console.log("fd_pwrite", fd, iovs, iovsLen, offset, nwritten);
        if (fd === CANVAS_FILENO || fd === WASI_STDOUT_FILENO || fd === WASI_STDERR_FILENO) {
          return this.exports().fd_write(fd, iovs, iovsLen, nwritten);
        }
        return 8;
      },
      fd_seek: () => {
        return 0;
      },
      fd_fdstat_get: () => {
        return 0;
      },
      fd_fdstat_set_flags: () => {
        return 0;
      },
      path_open: () => {
        return 8;
      },
      path_rename: () => {
        return 0;
      },
      path_create_directory: () => {
        return 0;
      },
      path_remove_directory: () => {
        return 0;
      },
      path_unlink_file: () => {
        return 0;
      },
      path_filestat_get: () => {
        return 0;
      },
      fd_filestat_get: () => {
        return 0;
      },
      random_get: (buf_ptr, buf_len) => {
        const buffer = new Uint8Array(this.memory.buffer, buf_ptr, buf_len);
        crypto.getRandomValues(buffer);
        return 0;
      },
      clock_time_get: (clock_id, precision, timestamp_out) => {
        const view = this.getDataView();
        switch (clock_id) {
          case CLOCK.REALTIME:
          case CLOCK.MONOTONIC: {
            const t = BigInt(Date.now()) * BigInt(1e6);
            view.setBigUint64(timestamp_out, t, true);
            break;
          }
          case CLOCK.PROCESS_CPUTIME_ID:
          case CLOCK.THREAD_CPUTIME_ID: {
            const t = BigInt(Math.floor(performance.now() * 1e6));
            view.setBigUint64(timestamp_out, t, true);
            break;
          }
          default:
            console.warn(`[WASI] Unhandled clock type: ${clock_id}`);
            return 1;
        }
        return 0;
      },
      environ_sizes_get: () => {
        return 0;
      },
      environ_get: () => {
        return 0;
      },
      args_sizes_get: () => {
        return 0;
      },
      args_get: () => {
        return 0;
      }
    };
  }
}

// src/spectrum.ts
class SpectrumWasm {
  instance = null;
  canvases = [];
  gradients = [];
  dataArray = null;
  dataProcessor = null;
  wasi = null;
  currentCanvasRef = 0;
  dataF32 = null;
  mode = "arc_safe";
  async initialize(canvas, analyser) {
    const ctx = canvas.getContext("2d");
    const canvasRef = this.canvases.length;
    this.canvases.push(ctx);
    this.gradients.push(null);
    this.wasi = new WASI;
    const imports = {
      wasi_snapshot_preview1: this.wasi.exports(),
      env: {}
    };
    const { instance } = await WebAssembly.instantiateStreaming(fetch("spectrum.wasm"), imports);
    if (!instance) {
      throw new Error("Failed to instantiate WASM module");
    }
    this.instance = instance;
    const memory = this.instance.exports.memory;
    this.wasi.setMemory(memory);
    this.dataProcessor = createCanvasDataProcessor();
    this.wasi.setCanvasProcessor((buffer, length) => {
      const validData = new Uint8Array(buffer, 0, length);
      this.dataProcessor.accumulator.addChunk(validData.buffer.slice(validData.byteOffset, validData.byteOffset + length));
    });
    this.dataProcessor.processor.addCanvas(ctx);
    this.currentCanvasRef = canvasRef;
    const debug = new URL(location.href).searchParams.get("debug") === "1";
    const m = new URL(location.href).searchParams.get("mode");
    if (m === "bars" || m === "arc_safe" || m === "arc")
      this.mode = m;
    const capture = new URL(location.href).searchParams.get("capture") === "1";
    if (debug) {
      const ver = this.instance.exports.spectrum_version?.() ?? "?";
      console.log("SpectrumWASM version:", ver);
    }
    const _init = this.instance.exports._initialize;
    _init();
    const initFn = this.instance.exports.spectrum_init;
    if (initFn) {
      initFn(canvasRef);
    }
    const setSize = this.instance.exports.spectrum_set_canvas_size;
    setSize(canvas.width, canvas.height);
    const setDb = this.instance.exports.spectrum_set_db_range;
    if (setDb)
      setDb(analyser.minDecibels, analyser.maxDecibels);
    const setAudio = this.instance.exports.spectrum_set_audio_info;
    if (setAudio)
      setAudio(analyser.context.sampleRate, analyser.fftSize);
    const setAgc = this.instance.exports.spectrum_set_agc;
    if (setAgc)
      setAgc(0.65, 0.25, 0.95, 0.6, 3.5);
    const setVocal = this.instance.exports.spectrum_set_vocal;
    if (setVocal)
      setVocal(2500, 0.9, 0.3);
    const setMap = this.instance.exports.spectrum_set_mapping;
    const setPresence = this.instance.exports.spectrum_set_presence_range;
    const setTrackParams = this.instance.exports.spectrum_set_track_params;
    if (this.mode === "arc") {
      setMap?.(0.6, 120);
      setPresence?.(200, 8000);
      setTrackParams?.(6, 12, 10, 0, 0, 0);
    } else {
      setMap?.(0.55, 220);
      setPresence?.(1600, 5200);
      setTrackParams?.(6, 12, 8, 0.6, 0.12, 2);
    }
    if (debug) {
      try {
        let last = 0;
        const el = document.createElement("div");
        el.style.position = "fixed";
        el.style.bottom = "8px";
        el.style.left = "8px";
        el.style.padding = "4px 8px";
        el.style.background = "rgba(0,0,0,0.35)";
        el.style.color = "#fff";
        el.style.font = "12px ui-monospace, monospace";
        el.style.zIndex = "99999";
        const modeLabel = this.mode === "bars" ? "bars_u8" : this.mode === "arc_safe" ? "arc_u8" : "arc_f32+tracks";
        el.textContent = `viz: ${modeLabel}`;
        document.body.appendChild(el);
        const panel = document.createElement("div");
        panel.style.position = "fixed";
        panel.style.bottom = "8px";
        panel.style.right = "8px";
        panel.style.padding = "8px";
        panel.style.background = "rgba(0,0,0,0.35)";
        panel.style.color = "#fff";
        panel.style.font = "12px ui-monospace, monospace";
        panel.style.zIndex = "99999";
        panel.style.display = "grid";
        panel.style.gridTemplateColumns = "auto auto";
        panel.style.gap = "6px 8px";
        const add = (label, input) => {
          const l = document.createElement("div");
          l.textContent = label;
          panel.appendChild(l);
          panel.appendChild(input);
        };
        const make = (min, max, step, val, cb) => {
          const i = document.createElement("input");
          i.type = "range";
          i.min = String(min);
          i.max = String(max);
          i.step = String(step);
          i.value = String(val);
          i.oninput = () => cb(Number(i.value));
          return i;
        };
        const setPresenceRange = this.instance.exports.spectrum_set_presence_range;
        const setTrackParams2 = this.instance.exports.spectrum_set_track_params;
        const setMapCfg = this.instance.exports.spectrum_set_mapping;
        add("presMin(Hz)", make(800, 6000, 50, 1600, (v) => setPresenceRange?.(v, presMax.valueAsNumber)));
        const presMax = make(2000, 8000, 50, 5200, (v) => setPresenceRange?.(presMin.valueAsNumber, v));
        const presMin = panel.querySelector("input[type=range]");
        add("presMax(Hz)", presMax);
        const stab = make(40, 95, 1, 60, (v) => setTrackParams2?.(6, 12, 8, v / 100, 12 / 100, 2));
        add("stab(%)", stab);
        const minAge = make(0, 6, 1, 2, (v) => setTrackParams2?.(6, 12, 8, stab.valueAsNumber / 100, 12 / 100, v));
        add("minAge(fr)", minAge);
        const alpha = make(30, 100, 1, 55, (v) => setMapCfg?.(v / 100, 220));
        add("mapAlpha", alpha);
        const setLead = this.instance.exports.spectrum_set_lead_style;
        const offset = make(0, 20, 1, 6, (v) => setLead?.(v));
        add("leadOffset", offset);
        document.body.appendChild(panel);
        const getTracks = this.instance.exports.spectrum_track_count;
        const dbgPre = this.instance.exports.spectrum_dbg_pre;
        const dbgPost = this.instance.exports.spectrum_dbg_post;
        const dbgMin = this.instance.exports.spectrum_dbg_dbmin;
        const dbgMax = this.instance.exports.spectrum_dbg_dbmax;
        const tick = () => {
          try {
            const n = getTracks?.() ?? 0;
            const modeLabel2 = this.mode === "bars" ? "bars_u8" : this.mode === "arc_safe" ? "arc_u8" : "arc_f32+tracks";
            const pre = dbgPre?.().toFixed(3);
            const post = dbgPost?.().toFixed(3);
            const dmin = dbgMin?.().toFixed(1);
            const dmax = dbgMax?.().toFixed(1);
            el.textContent = `viz: ${modeLabel2} | tracks=${n} | pre=${pre} post=${post} dB=[${dmin},${dmax}]`;
          } catch {}
          setTimeout(tick, 1000);
        };
        tick();
      } catch (err) {
        console.warn("debug HUD init failed", err);
      }
    }
    this.dataArray = new Uint8Array(analyser.frequencyBinCount);
    this.dataF32 = new Float32Array(new ArrayBuffer(analyser.frequencyBinCount * 4));
    return canvasRef;
  }
  draw(analyser, canvasRef = 0) {
    console.log("draw");
    if (!this.instance)
      return;
    if (this.mode === "bars") {
      if (!this.dataArray)
        this.dataArray = new Uint8Array(analyser.frequencyBinCount);
      analyser.getByteFrequencyData(this.dataArray);
      const memory2 = this.instance.exports.memory;
      const dataPtr2 = 1024 >>> 0;
      new Uint8Array(memory2.buffer, dataPtr2, this.dataArray.length).set(this.dataArray);
      const drawBars = this.instance.exports.spectrum_draw_bars;
      drawBars(canvasRef, dataPtr2, this.dataArray.length);
      return;
    }
    if (this.mode === "arc_safe") {
      if (!this.dataF32)
        this.dataF32 = new Float32Array(new ArrayBuffer(analyser.frequencyBinCount * 4));
      analyser.getFloatFrequencyData(this.dataF32);
      const memory2 = this.instance.exports.memory;
      const getPtr = this.instance.exports.spectrum_input_ptr_f32;
      const dataPtr2 = getPtr?.() ?? 1024;
      new Float32Array(memory2.buffer, dataPtr2, this.dataF32.length).set(this.dataF32);
      const drawArcSimple = this.instance.exports.spectrum_draw_arc_simple_f32;
      drawArcSimple(canvasRef, dataPtr2, this.dataF32.length);
      return;
    }
    if (!this.dataF32)
      return;
    analyser.getFloatFrequencyData(this.dataF32);
    const memory = this.instance.exports.memory;
    let dataPtr = 1024;
    const getPtrF = this.instance.exports.spectrum_input_ptr_f32;
    const ptrF = getPtrF?.() ?? dataPtr;
    new Float32Array(memory.buffer, ptrF, this.dataF32.length).set(this.dataF32);
    const drawArcF32 = this.instance.exports.spectrum_draw_arc_f32;
    drawArcF32(canvasRef, ptrF, this.dataF32.length);
    if (new URL(location.href).searchParams.get("capture") === "1") {
      try {
        const dump = this.instance.exports.spectrum_dump_post_bins;
        const postLen = this.instance.exports.spectrum_post_len;
        const outPtr = getPtrF?.() ?? ptrF;
        const count = dump(outPtr, 2048);
        const bins = Array.from(new Float32Array(memory.buffer, outPtr, Math.min(count, 256)));
        const dbgPre = this.instance.exports.spectrum_dbg_pre;
        const dbgPost = this.instance.exports.spectrum_dbg_post;
        const dbgMin = this.instance.exports.spectrum_dbg_dbmin;
        const dbgMax = this.instance.exports.spectrum_dbg_dbmax;
        const payload = JSON.stringify({
          t: performance.now() / 1000,
          pre: dbgPre?.(),
          post: dbgPost?.(),
          db: [dbgMin?.(), dbgMax?.()],
          mode: this.mode,
          bins
        });
        fetch("/capture", { method: "POST", body: payload });
      } catch {}
    }
  }
  resize(width, height) {
    if (!this.instance)
      return;
    const setSize = this.instance.exports.spectrum_set_canvas_size;
    setSize(width, height);
  }
  addCanvas(canvas) {
    const ctx = canvas.getContext("2d");
    const ref = this.canvases.length;
    this.canvases.push(ctx);
    this.gradients.push(null);
    if (this.dataProcessor) {
      this.dataProcessor.processor.addCanvas(ctx);
    }
    return ref;
  }
  removeCanvas(ref) {
    if (ref >= 0 && ref < this.canvases.length) {
      this.canvases[ref] = null;
      this.gradients[ref] = null;
      if (this.dataProcessor) {
        this.dataProcessor.processor.removeCanvas(ref);
      }
    }
  }
  getBufferStats() {
    if (!this.instance)
      return null;
    const bufferSizeFn = this.instance.exports.canvas_cmd_buffer_size;
    if (bufferSizeFn) {
      return {
        commandCount: bufferSizeFn()
      };
    }
    return null;
  }
  cleanup() {
    this.instance = null;
    this.canvases = [];
    this.gradients = [];
    this.dataArray = null;
    this.dataProcessor = null;
    this.wasi = null;
  }
}
var instance = null;
var defaultCanvasRef = 0;
async function initSpectrumWasm(canvas, analyser) {
  if (!instance) {
    instance = new SpectrumWasm;
  }
  const canvasRef = await instance.initialize(canvas, analyser);
  if (defaultCanvasRef === 0) {
    defaultCanvasRef = canvasRef;
  }
  return { wasm: instance, canvasRef };
}

// src/index.ts
function waitForContentLoad() {
  return new Promise((resolve) => {
    if (document.readyState === "complete") {
      resolve();
    } else {
      window.addEventListener("DOMContentLoaded", () => resolve());
    }
  });
}
await waitForContentLoad();
function widget(tag, within = document) {
  return within.getElementsByTagName(tag)[0];
}
var audio = widget("audio");
var canvas = widget("canvas");
var visualizer = widget("figure");
var recordButton = widget("button", widget("menu"));
visualizer.addEventListener("click", () => {
  if (audio.paused) {
    audio.play();
  } else {
    audio.pause();
  }
});
var audioResponse = await fetch(not_my_fault_default, { mode: "cors" });
var audioBlob = await audioResponse.blob();
var audioUrl = URL.createObjectURL(audioBlob);
audio.src = audioUrl;
var audioContext = new window.AudioContext;
var analyser = audioContext.createAnalyser();
analyser.fftSize = 4096;
var source = audioContext.createMediaElementSource(audio);
source.connect(analyser);
analyser.connect(audioContext.destination);
function ensureInitialCanvasSize() {
  const dpr = Math.max(1, window.devicePixelRatio || 1);
  const w = Math.floor(canvas.clientWidth * dpr) || canvas.width;
  const h = Math.floor(canvas.clientHeight * dpr) || canvas.height;
  canvas.width = w;
  canvas.height = h;
}
ensureInitialCanvasSize();
var { wasm: spectrumVisualizer, canvasRef } = await initSpectrumWasm(canvas, analyser);
spectrumVisualizer.resize(canvas.width, canvas.height);
audio.onplaying = async () => {
  try {
    await audioContext.resume();
  } catch {}
};
audio.onseeked = () => {
  animateLyrics(audio.currentTime);
};
audio.onerror = () => {
  alert("Error loading audio");
};
var lines = transcription_simple_default.trim().split(`
`);
var ws = [];
var t0 = [];
var t1 = [];
for (const line of lines) {
  const [time, ...wordParts] = line.split(" ");
  const word = wordParts.join(" ");
  ws.push(word);
  t0.push(parseFloat(time));
  t1.push(parseFloat(time) + 1);
}
var n = ws.length;
t0.push(t1[n - 1]);
t1.push(Infinity);
for (let i = 0;i < n; i++) {
  t1[i] = t0[i + 1];
}
for (let i = 1;i < ws.length - 1; i++) {
  const sincePreviousStart = t0[i] - t0[i - 1];
  if (sincePreviousStart > 2) {
    ws.splice(i, 0, `
`);
    t0.splice(i, 0, t0[i] + 0.1);
    t1.splice(i, 0, t1[i] + 0.1);
  }
}
var wordtags = [];
var lyrics = document.createElement("figcaption");
for (const [i, word] of ws.entries()) {
  if (word == `
`) {
    const tag = linebreak();
    wordtags.push(tag);
    lyrics.appendChild(tag);
  } else {
    const tag = wordspan(word);
    wordtags.push(lyrics.appendChild(tag));
    if (word.endsWith(",")) {
      tag.insertAdjacentElement("afterend", linebreak());
    }
  }
}
widget("figcaption").replaceWith(lyrics);
animateLyrics(-Infinity);
function wordspan(word) {
  const tag = document.createElement("span");
  tag.textContent = word;
  return tag;
}
function linebreak() {
  const tag = document.createElement("div");
  tag.style.flexBasis = "100%";
  tag.style.height = "0";
  return tag;
}
function nextAnimationFrame() {
  return new Promise((resolve) => {
    requestAnimationFrame(() => {
      resolve();
    });
  });
}
function nextEventFrom(element, eventName) {
  return new Promise((resolve) => {
    element.addEventListener(eventName, (event) => resolve(event), {
      once: true
    });
  });
}
async function animate() {
  while (true) {
    console.log("animate");
    await nextEventFrom(audio, "playing");
    await audioContext.resume();
    console.log("resume");
    while (!audio.paused && !audio.ended) {
      await nextAnimationFrame();
      console.log("frame");
      spectrumVisualizer.draw(analyser, canvasRef);
      animateLyrics(audio.currentTime);
    }
  }
}
animate();
function animateLyrics(t) {
  let i = 0;
  while (i < ws.length) {
    const start = t0[i], end = start + 1, duration = end - start, center = start + duration / 2;
    const distance = start - t, intensity = Math.exp(-distance * distance * 2), pastFade = t > end ? Math.exp(-(t - end) * 0.5) : 1, final = intensity * pastFade;
    wordtags[i].style.opacity = String(final * 0.7);
    if (distance <= 0) {
      wordtags[i].scrollIntoView({ behavior: "smooth", block: "center" });
    }
    i++;
  }
}
function resizeCanvas() {
  const dpr = Math.max(1, window.devicePixelRatio || 1);
  const w = Math.floor(canvas.clientWidth * dpr);
  const h = Math.floor(canvas.clientHeight * dpr);
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
    spectrumVisualizer.resize(w, h);
  }
}
resizeCanvas();
window.addEventListener("resize", resizeCanvas);
var ctx = canvas.getContext("2d");
recordButton.onclick = async () => {
  try {
    audio.currentTime = 0;
    const stream = await navigator.mediaDevices.getDisplayMedia({
      video: { displaySurface: "browser" },
      audio: true,
      preferCurrentTab: true
    });
    const videoTrack = stream.getVideoTracks()[0];
    if (videoTrack.cropTo) {
      const cropTarget = await CropTarget.fromElement(visualizer);
      await videoTrack.cropTo(cropTarget);
    }
    const mediaRecorder = new MediaRecorder(stream, {
      mimeType: "video/webm"
    });
    const recordedChunks = [];
    mediaRecorder.ondataavailable = (event) => {
      if (event.data.size > 0) {
        recordedChunks.push(event.data);
      }
    };
    mediaRecorder.onstop = () => {
      const blob = new Blob(recordedChunks, { type: "video/webm" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "lyrics-video.webm";
      a.click();
      stream.getTracks().forEach((track) => track.stop());
    };
    mediaRecorder.start();
    updateStatus("Recording full song...");
    visualizer.classList.add("recording");
    if (audioContext.state === "suspended") {
      audioContext.resume();
    }
    audio.addEventListener("ended", () => {
      mediaRecorder.stop();
    });
    audio.play();
  } catch (err) {
    updateStatus("Error: " + err.message);
  }
};
function updateStatus(message) {
  console.info(message);
}

//# debugId=247033B794D78A0564756E2164756E21
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vc3JjL21ldGFwYWNrZXQtcmVhZGVyLnRzIiwgIi4uL3NyYy9jYW52YXMtZGF0YS1wcm9jZXNzb3IudHMiLCAiLi4vc3JjL3dhc2kudHMiLCAiLi4vc3JjL3NwZWN0cnVtLnRzIiwgIi4uL3NyYy9pbmRleC50cyJdLAogICJzb3VyY2VzQ29udGVudCI6IFsKICAgICIvLyBHZW5lcmljIG1ldGFwYWNrZXQgcmVhZGVyIGZvciBUeXBlU2NyaXB0XG4vLyBSZWFkcyBwYWNrZXQgcHJvdG9jb2wgYW5kIHJldHVybnMgdHlwZWQgYXJyYXlzXG4vLyBQYWNrZXQgYWNjdW11bGF0b3IgdXNpbmcgZ2VuZXJhdG9yIGZvciBlbGVnYW50IHN0YXRlIG1hY2hpbmVcbi8vIFByb3RvY29sOiBtZXRhc2xpY2UgaGVhZGVyICh1MzIpIGZvbGxvd2VkIGJ5IE4gc2xpY2VzLCBlYWNoIHdpdGggbGVuZ3RoIHByZWZpeCBhbmQgNC1ieXRlIGFsaWdubWVudCBwYWRkaW5nXG5cbmV4cG9ydCBjbGFzcyBQYWNrZXRBY2N1bXVsYXRvciB7XG4gIHByaXZhdGUgZ2VuZXJhdG9yOiBHZW5lcmF0b3I8bnVtYmVyLCBVaW50OEFycmF5W10sIFVpbnQ4QXJyYXk+IHwgbnVsbCA9IG51bGxcbiAgcHJpdmF0ZSBwZW5kaW5nRGF0YSA9IG5ldyBVaW50OEFycmF5KDApXG4gIHByaXZhdGUgb25GcmFtZTogKChzbGljZXM6IFVpbnQ4QXJyYXlbXSkgPT4gdm9pZCkgfCBudWxsID0gbnVsbFxuXG4gIGNvbnN0cnVjdG9yKG9uRnJhbWU6IChzbGljZXM6IFVpbnQ4QXJyYXlbXSkgPT4gdm9pZCkge1xuICAgIHRoaXMub25GcmFtZSA9IG9uRnJhbWVcbiAgICB0aGlzLnJlc2V0KClcbiAgfVxuXG4gIC8vIFRoZSBiZWF1dGlmdWwgZ2VuZXJhdG9yIHN0YXRlIG1hY2hpbmUgLSByZXR1cm5zIGFycmF5IG9mIHNsaWNlc1xuICBwcml2YXRlICpwYWNrZXRTdGF0ZU1hY2hpbmUoKTogR2VuZXJhdG9yPG51bWJlciwgVWludDhBcnJheVtdLCBVaW50OEFycmF5PiB7XG4gICAgd2hpbGUgKHRydWUpIHtcbiAgICAgIC8vIFJlYWQgbWV0YXNsaWNlIGhlYWRlciAoNCBieXRlcylcbiAgICAgIGNvbnN0IGhlYWRlckJ5dGVzID0geWllbGQqIHRoaXMucmVhZEV4YWN0bHkoNClcbiAgICAgIGNvbnN0IGhlYWRlclZpZXcgPSBuZXcgRGF0YVZpZXcoXG4gICAgICAgIGhlYWRlckJ5dGVzLmJ1ZmZlcixcbiAgICAgICAgaGVhZGVyQnl0ZXMuYnl0ZU9mZnNldCxcbiAgICAgICAgNCxcbiAgICAgIClcbiAgICAgIGNvbnN0IHNsaWNlQ291bnQgPSBoZWFkZXJWaWV3LmdldFVpbnQzMigwLCB0cnVlKVxuXG4gICAgICBjb25zdCBzbGljZXM6IFVpbnQ4QXJyYXlbXSA9IFtdXG5cbiAgICAgIC8vIFJlYWQgZWFjaCBzbGljZVxuICAgICAgZm9yIChsZXQgaSA9IDA7IGkgPCBzbGljZUNvdW50OyBpKyspIHtcbiAgICAgICAgLy8gUmVhZCBzbGljZSBsZW5ndGhcbiAgICAgICAgY29uc3QgbGVuZ3RoQnl0ZXMgPSB5aWVsZCogdGhpcy5yZWFkRXhhY3RseSg0KVxuICAgICAgICBjb25zdCBsZW5ndGhWaWV3ID0gbmV3IERhdGFWaWV3KFxuICAgICAgICAgIGxlbmd0aEJ5dGVzLmJ1ZmZlcixcbiAgICAgICAgICBsZW5ndGhCeXRlcy5ieXRlT2Zmc2V0LFxuICAgICAgICAgIDQsXG4gICAgICAgIClcbiAgICAgICAgY29uc3Qgc2xpY2VMZW5ndGggPSBsZW5ndGhWaWV3LmdldFVpbnQzMigwLCB0cnVlKVxuXG4gICAgICAgIC8vIFJlYWQgc2xpY2UgZGF0YVxuICAgICAgICBjb25zdCBzbGljZURhdGEgPSB5aWVsZCogdGhpcy5yZWFkRXhhY3RseShzbGljZUxlbmd0aClcbiAgICAgICAgc2xpY2VzLnB1c2goc2xpY2VEYXRhKVxuXG4gICAgICAgIC8vIFNraXAgcGFkZGluZyBieXRlcyB0byBtYWludGFpbiA0LWJ5dGUgYWxpZ25tZW50XG4gICAgICAgIGNvbnN0IHBhZGRpbmcgPSAoNCAtIChzbGljZUxlbmd0aCAlIDQpKSAlIDRcbiAgICAgICAgaWYgKHBhZGRpbmcgPiAwKSB7XG4gICAgICAgICAgY29uc3QgcGFkZGluZ0J5dGVzID0geWllbGQqIHRoaXMucmVhZEV4YWN0bHkocGFkZGluZylcbiAgICAgICAgfVxuICAgICAgfVxuXG4gICAgICAvLyBSZXR1cm4gYXJyYXkgb2Ygc2xpY2VzIGRpcmVjdGx5IC0gbm8gcmVjb25zdHJ1Y3Rpb24hXG4gICAgICByZXR1cm4gc2xpY2VzXG4gICAgfVxuICB9XG5cbiAgLy8gSGVscGVyIGdlbmVyYXRvciB0byByZWFkIGV4YWN0bHkgTiBieXRlc1xuICBwcml2YXRlICpyZWFkRXhhY3RseShuOiBudW1iZXIpOiBHZW5lcmF0b3I8bnVtYmVyLCBVaW50OEFycmF5LCBVaW50OEFycmF5PiB7XG4gICAgd2hpbGUgKHRoaXMucGVuZGluZ0RhdGEubGVuZ3RoIDwgbikge1xuICAgICAgLy8gUmVxdWVzdCBtb3JlIGRhdGEgLSB5aWVsZCBob3cgbWFueSBieXRlcyB3ZSBzdGlsbCBuZWVkXG4gICAgICBjb25zdCBuZXdEYXRhID0geWllbGQgbiAtIHRoaXMucGVuZGluZ0RhdGEubGVuZ3RoXG5cbiAgICAgIC8vIEFwcGVuZCBuZXcgZGF0YSB0byBwZW5kaW5nXG4gICAgICBjb25zdCBjb21iaW5lZCA9IG5ldyBVaW50OEFycmF5KFxuICAgICAgICB0aGlzLnBlbmRpbmdEYXRhLmxlbmd0aCArIG5ld0RhdGEubGVuZ3RoLFxuICAgICAgKVxuICAgICAgY29tYmluZWQuc2V0KHRoaXMucGVuZGluZ0RhdGEpXG4gICAgICBjb21iaW5lZC5zZXQobmV3RGF0YSwgdGhpcy5wZW5kaW5nRGF0YS5sZW5ndGgpXG4gICAgICB0aGlzLnBlbmRpbmdEYXRhID0gY29tYmluZWRcbiAgICB9XG5cbiAgICAvLyBFeHRyYWN0IGV4YWN0bHkgbiBieXRlc1xuICAgIGNvbnN0IHJlc3VsdCA9IHRoaXMucGVuZGluZ0RhdGEuc2xpY2UoMCwgbilcbiAgICB0aGlzLnBlbmRpbmdEYXRhID0gdGhpcy5wZW5kaW5nRGF0YS5zbGljZShuKVxuXG4gICAgcmV0dXJuIHJlc3VsdFxuICB9XG5cbiAgLy8gRmVlZCBkYXRhIHRvIHRoZSBnZW5lcmF0b3JcbiAgYWRkQ2h1bmsoY2h1bms6IEFycmF5QnVmZmVyKSB7XG4gICAgY29uc3QgZGF0YSA9IG5ldyBVaW50OEFycmF5KGNodW5rKVxuXG4gICAgaWYgKCF0aGlzLmdlbmVyYXRvcikge1xuICAgICAgdGhpcy5yZXNldCgpXG4gICAgfVxuXG4gICAgbGV0IHRvRmVlZCA9IGRhdGFcblxuICAgIHdoaWxlICh0b0ZlZWQubGVuZ3RoID4gMCkge1xuICAgICAgY29uc3QgcmVzdWx0ID0gdGhpcy5nZW5lcmF0b3IhLm5leHQodG9GZWVkKVxuXG4gICAgICBpZiAocmVzdWx0LmRvbmUpIHtcbiAgICAgICAgLy8gRnJhbWUgY29tcGxldGUhIEdvdCBhcnJheSBvZiBzbGljZXNcbiAgICAgICAgaWYgKHRoaXMub25GcmFtZSkge1xuICAgICAgICAgIHRoaXMub25GcmFtZShyZXN1bHQudmFsdWUpXG4gICAgICAgIH1cblxuICAgICAgICAvLyBTdGFydCBuZXcgZnJhbWVcbiAgICAgICAgdGhpcy5nZW5lcmF0b3IgPSB0aGlzLnBhY2tldFN0YXRlTWFjaGluZSgpXG4gICAgICAgIHRoaXMuZ2VuZXJhdG9yLm5leHQoKSAvLyBJbml0aWFsaXplIHRvIGZpcnN0IHlpZWxkXG5cbiAgICAgICAgLy8gQ29udGludWUgZmVlZGluZyBpZiB3ZSBoYXZlIG1vcmUgZGF0YVxuICAgICAgICB0b0ZlZWQgPSB0aGlzLnBlbmRpbmdEYXRhXG4gICAgICAgIHRoaXMucGVuZGluZ0RhdGEgPSBuZXcgVWludDhBcnJheSgwKVxuICAgICAgfSBlbHNlIHtcbiAgICAgICAgLy8gR2VuZXJhdG9yIGlzIHJlcXVlc3RpbmcgbW9yZSBkYXRhXG4gICAgICAgIC8vIHJlc3VsdC52YWx1ZSBpcyBob3cgbWFueSBieXRlcyBpdCBuZWVkc1xuICAgICAgICBicmVha1xuICAgICAgfVxuICAgIH1cbiAgfVxuXG4gIHJlc2V0KCkge1xuICAgIHRoaXMuZ2VuZXJhdG9yID0gdGhpcy5wYWNrZXRTdGF0ZU1hY2hpbmUoKVxuICAgIHRoaXMuZ2VuZXJhdG9yLm5leHQoKSAvLyBJbml0aWFsaXplIHRvIGZpcnN0IHlpZWxkXG4gICAgdGhpcy5wZW5kaW5nRGF0YSA9IG5ldyBVaW50OEFycmF5KDApXG4gIH1cblxuICAvLyBEZWJ1ZyBpbmZvXG4gIGdldFN0YXRlKCkge1xuICAgIHJldHVybiB7XG4gICAgICBwZW5kaW5nQnl0ZXM6IHRoaXMucGVuZGluZ0RhdGEubGVuZ3RoLFxuICAgICAgaXNBY3RpdmU6IHRoaXMuZ2VuZXJhdG9yICE9PSBudWxsLFxuICAgIH1cbiAgfVxufVxuXG4vLyBJbnRlZ3JhdGlvbiB3aXRoIGNhbnZhcyBwcm9jZXNzb3IgLSBkaXJlY3RseSB1c2Ugc2xpY2VzIVxuZXhwb3J0IGZ1bmN0aW9uIGNyZWF0ZUNhbnZhc1BhY2tldEhhbmRsZXIoXG4gIG9uRnJhbWU6IChcbiAgICBwb2ludHM6IEludDE2QXJyYXksXG4gICAgcmdiczogVWludDhBcnJheSxcbiAgICB0YWdzOiBVaW50MTZBcnJheSxcbiAgICBkYXRhOiBVaW50OEFycmF5LFxuICApID0+IHZvaWQsXG4pIHtcbiAgcmV0dXJuIG5ldyBQYWNrZXRBY2N1bXVsYXRvcigoc2xpY2VzOiBVaW50OEFycmF5W10pID0+IHtcbiAgICBpZiAoc2xpY2VzLmxlbmd0aCAhPT0gNCkge1xuICAgICAgY29uc29sZS5lcnJvcihgRXhwZWN0ZWQgNCBzbGljZXMsIGdvdCAke3NsaWNlcy5sZW5ndGh9YClcbiAgICAgIHJldHVyblxuICAgIH1cblxuICAgIC8vIENyZWF0ZSB0eXBlZCB2aWV3cyBkaXJlY3RseSBvbiB0aGUgc2xpY2UgYnVmZmVyc1xuICAgIC8vIFNsaWNlIDA6IFBvaW50cyAoVmVjMiA9IGkxNiBwYWlycylcbiAgICBjb25zdCBwb2ludHMgPSBuZXcgSW50MTZBcnJheShcbiAgICAgIHNsaWNlc1swXS5idWZmZXIsXG4gICAgICBzbGljZXNbMF0uYnl0ZU9mZnNldCxcbiAgICAgIHNsaWNlc1swXS5ieXRlTGVuZ3RoIC8gMixcbiAgICApXG5cbiAgICAvLyBTbGljZSAxOiBSR0JzIChyYXcgYnl0ZXMpXG4gICAgY29uc3QgcmdicyA9IHNsaWNlc1sxXVxuXG4gICAgLy8gU2xpY2UgMjogVGFncyAocmF3IGJ5dGVzIGZvciBub3csIGNvdWxkIGJlIHUxNilcbiAgICBjb25zdCB0YWdzID0gbmV3IFVpbnQxNkFycmF5KFxuICAgICAgc2xpY2VzWzJdLmJ1ZmZlcixcbiAgICAgIHNsaWNlc1syXS5ieXRlT2Zmc2V0LFxuICAgICAgc2xpY2VzWzJdLmJ5dGVMZW5ndGggLyAyLFxuICAgIClcblxuICAgIC8vIFNsaWNlIDM6IENvbW1hbmQgZGF0YSAocmF3IGJ5dGVzKVxuICAgIGNvbnN0IGRhdGEgPSBzbGljZXNbM11cblxuICAgIG9uRnJhbWUocG9pbnRzLCByZ2JzLCB0YWdzLCBkYXRhKVxuICB9KVxufVxuXG4vLyBUeXBlIGRlZmluaXRpb25zIGZvciBkaWZmZXJlbnQgc2xpY2UgdHlwZXNcbmV4cG9ydCB0eXBlIFNsaWNlVHlwZSA9XG4gIHwgeyB0eXBlOiBcInU4XCI7IGFycmF5OiBVaW50OEFycmF5IH1cbiAgfCB7IHR5cGU6IFwidTE2XCI7IGFycmF5OiBVaW50MTZBcnJheSB9XG4gIHwgeyB0eXBlOiBcInUzMlwiOyBhcnJheTogVWludDMyQXJyYXkgfVxuICB8IHsgdHlwZTogXCJpMTZcIjsgYXJyYXk6IEludDE2QXJyYXkgfVxuICB8IHsgdHlwZTogXCJpMzJcIjsgYXJyYXk6IEludDMyQXJyYXkgfVxuICB8IHsgdHlwZTogXCJmMzJcIjsgYXJyYXk6IEZsb2F0MzJBcnJheSB9XG4gIHwgeyB0eXBlOiBcInZlYzJcIjsgYXJyYXk6IEludDE2QXJyYXkgfSAvLyBpMTYgcGFpcnNcbiAgfCB7IHR5cGU6IFwicmdiXCI7IGFycmF5OiBVaW50OEFycmF5IH0gLy8gdTggdHJpcGxldHNcbiAgfCB7IHR5cGU6IFwicmF3XCI7IGFycmF5OiBVaW50OEFycmF5IH0gLy8gUmF3IGJ5dGVzXG5cbi8vIFR5cGUtc2FmZSBzbGljZSBkZXNjcmlwdG9yXG5leHBvcnQgaW50ZXJmYWNlIFNsaWNlRGVzY3JpcHRvcjxUIGV4dGVuZHMgU2xpY2VUeXBlW1widHlwZVwiXT4ge1xuICB0eXBlOiBUXG4gIGVsZW1lbnRTaXplOiBudW1iZXJcbiAgY3JlYXRlVmlldzogKGJ1ZmZlcjogQXJyYXlCdWZmZXJMaWtlLCBvZmZzZXQ6IG51bWJlciwgbGVuZ3RoOiBudW1iZXIpID0+IGFueVxufVxuXG4vLyBTbGljZSBkZXNjcmlwdG9ycyBmb3IgY29tbW9uIHR5cGVzXG5leHBvcnQgY29uc3QgU2xpY2VUeXBlcyA9IHtcbiAgdTg6IHtcbiAgICB0eXBlOiBcInU4XCIsXG4gICAgZWxlbWVudFNpemU6IDEsXG4gICAgY3JlYXRlVmlldzogKGI6IEFycmF5QnVmZmVyTGlrZSwgbzogbnVtYmVyLCBsOiBudW1iZXIpID0+XG4gICAgICBuZXcgVWludDhBcnJheShiLCBvLCBsKSxcbiAgfSBhcyBTbGljZURlc2NyaXB0b3I8XCJ1OFwiPixcblxuICB1MTY6IHtcbiAgICB0eXBlOiBcInUxNlwiLFxuICAgIGVsZW1lbnRTaXplOiAyLFxuICAgIGNyZWF0ZVZpZXc6IChiOiBBcnJheUJ1ZmZlckxpa2UsIG86IG51bWJlciwgbDogbnVtYmVyKSA9PlxuICAgICAgbmV3IFVpbnQxNkFycmF5KGIsIG8sIGwgLyAyKSxcbiAgfSBhcyBTbGljZURlc2NyaXB0b3I8XCJ1MTZcIj4sXG5cbiAgdTMyOiB7XG4gICAgdHlwZTogXCJ1MzJcIixcbiAgICBlbGVtZW50U2l6ZTogNCxcbiAgICBjcmVhdGVWaWV3OiAoYjogQXJyYXlCdWZmZXJMaWtlLCBvOiBudW1iZXIsIGw6IG51bWJlcikgPT5cbiAgICAgIG5ldyBVaW50MzJBcnJheShiLCBvLCBsIC8gNCksXG4gIH0gYXMgU2xpY2VEZXNjcmlwdG9yPFwidTMyXCI+LFxuXG4gIGkxNjoge1xuICAgIHR5cGU6IFwiaTE2XCIsXG4gICAgZWxlbWVudFNpemU6IDIsXG4gICAgY3JlYXRlVmlldzogKGI6IEFycmF5QnVmZmVyTGlrZSwgbzogbnVtYmVyLCBsOiBudW1iZXIpID0+XG4gICAgICBuZXcgSW50MTZBcnJheShiLCBvLCBsIC8gMiksXG4gIH0gYXMgU2xpY2VEZXNjcmlwdG9yPFwiaTE2XCI+LFxuXG4gIGkzMjoge1xuICAgIHR5cGU6IFwiaTMyXCIsXG4gICAgZWxlbWVudFNpemU6IDQsXG4gICAgY3JlYXRlVmlldzogKGI6IEFycmF5QnVmZmVyTGlrZSwgbzogbnVtYmVyLCBsOiBudW1iZXIpID0+XG4gICAgICBuZXcgSW50MzJBcnJheShiLCBvLCBsIC8gNCksXG4gIH0gYXMgU2xpY2VEZXNjcmlwdG9yPFwiaTMyXCI+LFxuXG4gIGYzMjoge1xuICAgIHR5cGU6IFwiZjMyXCIsXG4gICAgZWxlbWVudFNpemU6IDQsXG4gICAgY3JlYXRlVmlldzogKGI6IEFycmF5QnVmZmVyTGlrZSwgbzogbnVtYmVyLCBsOiBudW1iZXIpID0+XG4gICAgICBuZXcgRmxvYXQzMkFycmF5KGIsIG8sIGwgLyA0KSxcbiAgfSBhcyBTbGljZURlc2NyaXB0b3I8XCJmMzJcIj4sXG5cbiAgdmVjMjoge1xuICAgIHR5cGU6IFwidmVjMlwiLFxuICAgIGVsZW1lbnRTaXplOiA0LFxuICAgIGNyZWF0ZVZpZXc6IChiOiBBcnJheUJ1ZmZlckxpa2UsIG86IG51bWJlciwgbDogbnVtYmVyKSA9PlxuICAgICAgbmV3IEludDE2QXJyYXkoYiwgbywgbCAvIDIpLFxuICB9IGFzIFNsaWNlRGVzY3JpcHRvcjxcInZlYzJcIj4sXG5cbiAgcmdiOiB7XG4gICAgdHlwZTogXCJyZ2JcIixcbiAgICBlbGVtZW50U2l6ZTogMyxcbiAgICBjcmVhdGVWaWV3OiAoYjogQXJyYXlCdWZmZXJMaWtlLCBvOiBudW1iZXIsIGw6IG51bWJlcikgPT5cbiAgICAgIG5ldyBVaW50OEFycmF5KGIsIG8sIGwpLFxuICB9IGFzIFNsaWNlRGVzY3JpcHRvcjxcInJnYlwiPixcblxuICByYXc6IHtcbiAgICB0eXBlOiBcInJhd1wiLFxuICAgIGVsZW1lbnRTaXplOiAxLFxuICAgIGNyZWF0ZVZpZXc6IChiOiBBcnJheUJ1ZmZlckxpa2UsIG86IG51bWJlciwgbDogbnVtYmVyKSA9PlxuICAgICAgbmV3IFVpbnQ4QXJyYXkoYiwgbywgbCksXG4gIH0gYXMgU2xpY2VEZXNjcmlwdG9yPFwicmF3XCI+LFxufSBhcyBjb25zdFxuXG4vLyBHZW5lcmljIG1ldGFwYWNrZXQgcmVhZGVyXG5leHBvcnQgY2xhc3MgTWV0YXBhY2tldFJlYWRlcjxUIGV4dGVuZHMgcmVhZG9ubHkgU2xpY2VEZXNjcmlwdG9yPGFueT5bXT4ge1xuICBjb25zdHJ1Y3Rvcihwcml2YXRlIGRlc2NyaXB0b3JzOiBUKSB7fVxuXG4gIC8vIFBhcnNlIGEgY29tcGxldGUgbWV0YXBhY2tldCBidWZmZXJcbiAgcGFyc2UoYnVmZmVyOiBVaW50OEFycmF5KTogRXh0cmFjdFNsaWNlVHlwZXM8VD4ge1xuICAgIGNvbnN0IHZpZXcgPSBuZXcgRGF0YVZpZXcoXG4gICAgICBidWZmZXIuYnVmZmVyLFxuICAgICAgYnVmZmVyLmJ5dGVPZmZzZXQsXG4gICAgICBidWZmZXIuYnl0ZUxlbmd0aCxcbiAgICApXG4gICAgbGV0IHBvcyA9IDBcblxuICAgIC8vIFJlYWQgbWV0YXNsaWNlIGhlYWRlclxuICAgIGNvbnN0IHNsaWNlQ291bnQgPSB2aWV3LmdldFVpbnQzMihwb3MsIHRydWUpXG4gICAgcG9zICs9IDRcblxuICAgIGlmIChzbGljZUNvdW50ICE9PSB0aGlzLmRlc2NyaXB0b3JzLmxlbmd0aCkge1xuICAgICAgdGhyb3cgbmV3IEVycm9yKFxuICAgICAgICBgRXhwZWN0ZWQgJHt0aGlzLmRlc2NyaXB0b3JzLmxlbmd0aH0gc2xpY2VzLCBnb3QgJHtzbGljZUNvdW50fWAsXG4gICAgICApXG4gICAgfVxuXG4gICAgY29uc3QgcmVzdWx0OiBhbnlbXSA9IFtdXG5cbiAgICAvLyBSZWFkIGVhY2ggc2xpY2VcbiAgICBmb3IgKGxldCBpID0gMDsgaSA8IHNsaWNlQ291bnQ7IGkrKykge1xuICAgICAgY29uc3QgZGVzY3JpcHRvciA9IHRoaXMuZGVzY3JpcHRvcnNbaV1cblxuICAgICAgLy8gUmVhZCBzbGljZSBsZW5ndGhcbiAgICAgIGNvbnN0IGJ5dGVMZW5ndGggPSB2aWV3LmdldFVpbnQzMihwb3MsIHRydWUpXG4gICAgICBwb3MgKz0gNFxuXG4gICAgICAvLyBDcmVhdGUgdHlwZWQgdmlldyBmb3IgdGhpcyBzbGljZVxuICAgICAgY29uc3Qgc2xpY2VWaWV3ID0gZGVzY3JpcHRvci5jcmVhdGVWaWV3KFxuICAgICAgICBidWZmZXIuYnVmZmVyLFxuICAgICAgICBidWZmZXIuYnl0ZU9mZnNldCArIHBvcyxcbiAgICAgICAgYnl0ZUxlbmd0aCxcbiAgICAgIClcblxuICAgICAgcmVzdWx0LnB1c2goc2xpY2VWaWV3KVxuICAgICAgcG9zICs9IGJ5dGVMZW5ndGhcbiAgICAgIC8vIFNraXAgcGFkZGluZyB0byA0LWJ5dGUgYm91bmRhcnkgKHdyaXRlciBwYWRzIGFmdGVyIGVhY2ggc2xpY2UpXG4gICAgICBjb25zdCBwYWQgPSAoNCAtIChieXRlTGVuZ3RoICUgNCkpICUgNFxuICAgICAgcG9zICs9IHBhZFxuICAgIH1cblxuICAgIHJldHVybiByZXN1bHQgYXMgRXh0cmFjdFNsaWNlVHlwZXM8VD5cbiAgfVxufVxuXG4vLyBUeXBlIGhlbHBlciB0byBleHRyYWN0IHR1cGxlIG9mIGFycmF5IHR5cGVzIGZyb20gZGVzY3JpcHRvcnNcbnR5cGUgRXh0cmFjdFNsaWNlVHlwZXM8VCBleHRlbmRzIHJlYWRvbmx5IFNsaWNlRGVzY3JpcHRvcjxhbnk+W10+ID0ge1xuICBbSyBpbiBrZXlvZiBUXTogVFtLXSBleHRlbmRzIFNsaWNlRGVzY3JpcHRvcjxpbmZlciBVPlxuICAgID8gVSBleHRlbmRzIFwidThcIlxuICAgICAgPyBVaW50OEFycmF5XG4gICAgICA6IFUgZXh0ZW5kcyBcInUxNlwiXG4gICAgICA/IFVpbnQxNkFycmF5XG4gICAgICA6IFUgZXh0ZW5kcyBcInUzMlwiXG4gICAgICA/IFVpbnQzMkFycmF5XG4gICAgICA6IFUgZXh0ZW5kcyBcImkxNlwiXG4gICAgICA/IEludDE2QXJyYXlcbiAgICAgIDogVSBleHRlbmRzIFwiaTMyXCJcbiAgICAgID8gSW50MzJBcnJheVxuICAgICAgOiBVIGV4dGVuZHMgXCJmMzJcIlxuICAgICAgPyBGbG9hdDMyQXJyYXlcbiAgICAgIDogVSBleHRlbmRzIFwidmVjMlwiXG4gICAgICA/IEludDE2QXJyYXlcbiAgICAgIDogVSBleHRlbmRzIFwicmdiXCJcbiAgICAgID8gVWludDhBcnJheVxuICAgICAgOiBVIGV4dGVuZHMgXCJyYXdcIlxuICAgICAgPyBVaW50OEFycmF5XG4gICAgICA6IG5ldmVyXG4gICAgOiBuZXZlclxufVxuXG4vLyBDYW52YXMtc3BlY2lmaWMgcmVhZGVyXG5leHBvcnQgY29uc3QgQ2FudmFzTWV0YXBhY2tldFJlYWRlciA9IG5ldyBNZXRhcGFja2V0UmVhZGVyKFtcbiAgU2xpY2VUeXBlcy52ZWMyLCAvLyBwb2ludHNcbiAgU2xpY2VUeXBlcy5yZ2IsIC8vIGNvbG9yc1xuICBTbGljZVR5cGVzLnUxNiwgLy8gdGFnc1xuICBTbGljZVR5cGVzLnJhdywgLy8gY29tbWFuZCBkYXRhXG5dIGFzIGNvbnN0KVxuXG4vLyBVc2FnZSBleGFtcGxlOlxuLy8gY29uc3QgW3BvaW50cywgcmdicywgdGFncywgZGF0YV0gPSBDYW52YXNNZXRhcGFja2V0UmVhZGVyLnBhcnNlKGZyYW1lQnVmZmVyKVxuLy8gcG9pbnRzIGlzIHR5cGVkIGFzIEludDE2QXJyYXlcbi8vIHJnYnMgaXMgdHlwZWQgYXMgVWludDhBcnJheVxuLy8gdGFncyBpcyB0eXBlZCBhcyBVaW50OEFycmF5XG4vLyBkYXRhIGlzIHR5cGVkIGFzIFVpbnQ4QXJyYXlcblxuLy8gSGVscGVyIHRvIGNyZWF0ZSB2ZWMyIGFjY2Vzc29yXG5leHBvcnQgZnVuY3Rpb24gY3JlYXRlVmVjMkFjY2Vzc29yKGFycmF5OiBJbnQxNkFycmF5KSB7XG4gIHJldHVybiB7XG4gICAgY291bnQ6IGFycmF5Lmxlbmd0aCAvIDIsXG4gICAgZ2V0KGluZGV4OiBudW1iZXIpOiB7IHg6IG51bWJlcjsgeTogbnVtYmVyIH0ge1xuICAgICAgcmV0dXJuIHtcbiAgICAgICAgeDogYXJyYXlbaW5kZXggKiAyXSxcbiAgICAgICAgeTogYXJyYXlbaW5kZXggKiAyICsgMV0sXG4gICAgICB9XG4gICAgfSxcbiAgICBhcnJheSxcbiAgfVxufVxuXG4vLyBIZWxwZXIgdG8gY3JlYXRlIFJHQiBhY2Nlc3NvclxuZXhwb3J0IGZ1bmN0aW9uIGNyZWF0ZVJnYkFjY2Vzc29yKGFycmF5OiBVaW50OEFycmF5KSB7XG4gIHJldHVybiB7XG4gICAgY291bnQ6IGFycmF5Lmxlbmd0aCAvIDMsXG4gICAgZ2V0KGluZGV4OiBudW1iZXIpOiB7IHI6IG51bWJlcjsgZzogbnVtYmVyOyBiOiBudW1iZXIgfSB7XG4gICAgICByZXR1cm4ge1xuICAgICAgICByOiBhcnJheVtpbmRleCAqIDNdLFxuICAgICAgICBnOiBhcnJheVtpbmRleCAqIDMgKyAxXSxcbiAgICAgICAgYjogYXJyYXlbaW5kZXggKiAzICsgMl0sXG4gICAgICB9XG4gICAgfSxcbiAgICBhcnJheSxcbiAgfVxufVxuIiwKICAgICIvLyBDYW52YXMgZGF0YS1vcmllbnRlZCBmb3JtYXQgcHJvY2Vzc29yXG4vLyBSZWFkcyB0aGUgbmV3IE11bHRpQXJyYXlMaXN0LWJhc2VkIGNvbW1hbmQgc3RyZWFtXG5cbmltcG9ydCB7XG4gIENhbnZhc01ldGFwYWNrZXRSZWFkZXIsXG4gIGNyZWF0ZVZlYzJBY2Nlc3NvcixcbiAgY3JlYXRlUmdiQWNjZXNzb3IsXG59IGZyb20gXCIuL21ldGFwYWNrZXQtcmVhZGVyXCJcblxuZXhwb3J0IGNsYXNzIFBhY2tldEFjY3VtdWxhdG9yIHtcbiAgcHJpdmF0ZSBnZW5lcmF0b3I6IEdlbmVyYXRvcjxudW1iZXIsIFVpbnQ4QXJyYXlbXSwgVWludDhBcnJheT4gfCBudWxsID0gbnVsbFxuICBwcml2YXRlIHBlbmRpbmdEYXRhID0gbmV3IFVpbnQ4QXJyYXkoMClcbiAgcHJpdmF0ZSBvbkZyYW1lOiAoKHNsaWNlczogVWludDhBcnJheVtdKSA9PiB2b2lkKSB8IG51bGwgPSBudWxsXG5cbiAgY29uc3RydWN0b3Iob25GcmFtZTogKHNsaWNlczogVWludDhBcnJheVtdKSA9PiB2b2lkKSB7XG4gICAgdGhpcy5vbkZyYW1lID0gb25GcmFtZVxuICAgIHRoaXMucmVzZXQoKVxuICB9XG5cbiAgLy8gVGhlIGJlYXV0aWZ1bCBnZW5lcmF0b3Igc3RhdGUgbWFjaGluZSAtIHJldHVybnMgYXJyYXkgb2Ygc2xpY2VzXG4gIHByaXZhdGUgKnBhY2tldFN0YXRlTWFjaGluZSgpOiBHZW5lcmF0b3I8bnVtYmVyLCBVaW50OEFycmF5W10sIFVpbnQ4QXJyYXk+IHtcbiAgICB3aGlsZSAodHJ1ZSkge1xuICAgICAgLy8gUmVhZCBtZXRhc2xpY2UgaGVhZGVyICg0IGJ5dGVzKVxuICAgICAgY29uc3QgaGVhZGVyQnl0ZXMgPSB5aWVsZCogdGhpcy5yZWFkRXhhY3RseSg0KVxuICAgICAgY29uc3QgaGVhZGVyVmlldyA9IG5ldyBEYXRhVmlldyhcbiAgICAgICAgaGVhZGVyQnl0ZXMuYnVmZmVyLFxuICAgICAgICBoZWFkZXJCeXRlcy5ieXRlT2Zmc2V0LFxuICAgICAgICA0LFxuICAgICAgKVxuICAgICAgY29uc3Qgc2xpY2VDb3VudCA9IGhlYWRlclZpZXcuZ2V0VWludDMyKDAsIHRydWUpXG5cbiAgICAgIGNvbnN0IHNsaWNlczogVWludDhBcnJheVtdID0gW11cblxuICAgICAgLy8gUmVhZCBlYWNoIHNsaWNlXG4gICAgICBmb3IgKGxldCBpID0gMDsgaSA8IHNsaWNlQ291bnQ7IGkrKykge1xuICAgICAgICAvLyBSZWFkIHNsaWNlIGxlbmd0aFxuICAgICAgICBjb25zdCBsZW5ndGhCeXRlcyA9IHlpZWxkKiB0aGlzLnJlYWRFeGFjdGx5KDQpXG4gICAgICAgIGNvbnN0IGxlbmd0aFZpZXcgPSBuZXcgRGF0YVZpZXcoXG4gICAgICAgICAgbGVuZ3RoQnl0ZXMuYnVmZmVyLFxuICAgICAgICAgIGxlbmd0aEJ5dGVzLmJ5dGVPZmZzZXQsXG4gICAgICAgICAgNCxcbiAgICAgICAgKVxuICAgICAgICBjb25zdCBzbGljZUxlbmd0aCA9IGxlbmd0aFZpZXcuZ2V0VWludDMyKDAsIHRydWUpXG5cbiAgICAgICAgLy8gUmVhZCBzbGljZSBkYXRhXG4gICAgICAgIGNvbnN0IHNsaWNlRGF0YSA9IHlpZWxkKiB0aGlzLnJlYWRFeGFjdGx5KHNsaWNlTGVuZ3RoKVxuICAgICAgICBzbGljZXMucHVzaChzbGljZURhdGEpXG5cbiAgICAgICAgLy8gU2tpcCBwYWRkaW5nIGJ5dGVzIHRvIG1haW50YWluIDQtYnl0ZSBhbGlnbm1lbnRcbiAgICAgICAgY29uc3QgcGFkZGluZyA9ICg0IC0gKHNsaWNlTGVuZ3RoICUgNCkpICUgNFxuICAgICAgICBpZiAocGFkZGluZyA+IDApIHtcbiAgICAgICAgICBjb25zdCBwYWRkaW5nQnl0ZXMgPSB5aWVsZCogdGhpcy5yZWFkRXhhY3RseShwYWRkaW5nKVxuICAgICAgICB9XG4gICAgICB9XG5cbiAgICAgIC8vIFJldHVybiBhcnJheSBvZiBzbGljZXMgZGlyZWN0bHkgLSBubyByZWNvbnN0cnVjdGlvbiFcbiAgICAgIHJldHVybiBzbGljZXNcbiAgICB9XG4gIH1cblxuICAvLyBIZWxwZXIgZ2VuZXJhdG9yIHRvIHJlYWQgZXhhY3RseSBOIGJ5dGVzXG4gIHByaXZhdGUgKnJlYWRFeGFjdGx5KG46IG51bWJlcik6IEdlbmVyYXRvcjxudW1iZXIsIFVpbnQ4QXJyYXksIFVpbnQ4QXJyYXk+IHtcbiAgICB3aGlsZSAodGhpcy5wZW5kaW5nRGF0YS5sZW5ndGggPCBuKSB7XG4gICAgICAvLyBSZXF1ZXN0IG1vcmUgZGF0YSAtIHlpZWxkIGhvdyBtYW55IGJ5dGVzIHdlIHN0aWxsIG5lZWRcbiAgICAgIGNvbnN0IG5ld0RhdGEgPSB5aWVsZCBuIC0gdGhpcy5wZW5kaW5nRGF0YS5sZW5ndGhcblxuICAgICAgLy8gQXBwZW5kIG5ldyBkYXRhIHRvIHBlbmRpbmdcbiAgICAgIGNvbnN0IGNvbWJpbmVkID0gbmV3IFVpbnQ4QXJyYXkoXG4gICAgICAgIHRoaXMucGVuZGluZ0RhdGEubGVuZ3RoICsgbmV3RGF0YS5sZW5ndGgsXG4gICAgICApXG4gICAgICBjb21iaW5lZC5zZXQodGhpcy5wZW5kaW5nRGF0YSlcbiAgICAgIGNvbWJpbmVkLnNldChuZXdEYXRhLCB0aGlzLnBlbmRpbmdEYXRhLmxlbmd0aClcbiAgICAgIHRoaXMucGVuZGluZ0RhdGEgPSBjb21iaW5lZFxuICAgIH1cblxuICAgIC8vIEV4dHJhY3QgZXhhY3RseSBuIGJ5dGVzXG4gICAgY29uc3QgcmVzdWx0ID0gdGhpcy5wZW5kaW5nRGF0YS5zbGljZSgwLCBuKVxuICAgIHRoaXMucGVuZGluZ0RhdGEgPSB0aGlzLnBlbmRpbmdEYXRhLnNsaWNlKG4pXG5cbiAgICByZXR1cm4gcmVzdWx0XG4gIH1cblxuICAvLyBGZWVkIGRhdGEgdG8gdGhlIGdlbmVyYXRvclxuICBhZGRDaHVuayhjaHVuazogQXJyYXlCdWZmZXIpIHtcbiAgICBjb25zdCBkYXRhID0gbmV3IFVpbnQ4QXJyYXkoY2h1bmspXG5cbiAgICBpZiAoIXRoaXMuZ2VuZXJhdG9yKSB7XG4gICAgICB0aGlzLnJlc2V0KClcbiAgICB9XG5cbiAgICBsZXQgdG9GZWVkID0gZGF0YVxuXG4gICAgd2hpbGUgKHRvRmVlZC5sZW5ndGggPiAwKSB7XG4gICAgICBjb25zdCByZXN1bHQgPSB0aGlzLmdlbmVyYXRvciEubmV4dCh0b0ZlZWQpXG5cbiAgICAgIGlmIChyZXN1bHQuZG9uZSkge1xuICAgICAgICAvLyBGcmFtZSBjb21wbGV0ZSEgR290IGFycmF5IG9mIHNsaWNlc1xuICAgICAgICBpZiAodGhpcy5vbkZyYW1lKSB7XG4gICAgICAgICAgdGhpcy5vbkZyYW1lKHJlc3VsdC52YWx1ZSlcbiAgICAgICAgfVxuXG4gICAgICAgIC8vIFN0YXJ0IG5ldyBmcmFtZVxuICAgICAgICB0aGlzLmdlbmVyYXRvciA9IHRoaXMucGFja2V0U3RhdGVNYWNoaW5lKClcbiAgICAgICAgdGhpcy5nZW5lcmF0b3IubmV4dCgpIC8vIEluaXRpYWxpemUgdG8gZmlyc3QgeWllbGRcblxuICAgICAgICAvLyBDb250aW51ZSBmZWVkaW5nIGlmIHdlIGhhdmUgbW9yZSBkYXRhXG4gICAgICAgIHRvRmVlZCA9IHRoaXMucGVuZGluZ0RhdGFcbiAgICAgICAgdGhpcy5wZW5kaW5nRGF0YSA9IG5ldyBVaW50OEFycmF5KDApXG4gICAgICB9IGVsc2Uge1xuICAgICAgICAvLyBHZW5lcmF0b3IgaXMgcmVxdWVzdGluZyBtb3JlIGRhdGFcbiAgICAgICAgLy8gcmVzdWx0LnZhbHVlIGlzIGhvdyBtYW55IGJ5dGVzIGl0IG5lZWRzXG4gICAgICAgIGJyZWFrXG4gICAgICB9XG4gICAgfVxuICB9XG5cbiAgcmVzZXQoKSB7XG4gICAgdGhpcy5nZW5lcmF0b3IgPSB0aGlzLnBhY2tldFN0YXRlTWFjaGluZSgpXG4gICAgdGhpcy5nZW5lcmF0b3IubmV4dCgpIC8vIEluaXRpYWxpemUgdG8gZmlyc3QgeWllbGRcbiAgICB0aGlzLnBlbmRpbmdEYXRhID0gbmV3IFVpbnQ4QXJyYXkoMClcbiAgfVxuXG4gIC8vIERlYnVnIGluZm9cbiAgZ2V0U3RhdGUoKSB7XG4gICAgcmV0dXJuIHtcbiAgICAgIHBlbmRpbmdCeXRlczogdGhpcy5wZW5kaW5nRGF0YS5sZW5ndGgsXG4gICAgICBpc0FjdGl2ZTogdGhpcy5nZW5lcmF0b3IgIT09IG51bGwsXG4gICAgfVxuICB9XG59XG5cbi8vIEludGVncmF0aW9uIHdpdGggY2FudmFzIHByb2Nlc3NvciAtIGRpcmVjdGx5IHVzZSBzbGljZXMhXG5leHBvcnQgZnVuY3Rpb24gY3JlYXRlQ2FudmFzUGFja2V0SGFuZGxlcihcbiAgb25GcmFtZTogKFxuICAgIHBvaW50czogSW50MTZBcnJheSxcbiAgICByZ2JzOiBVaW50OEFycmF5LFxuICAgIHRhZ3M6IFVpbnQxNkFycmF5LFxuICAgIGRhdGE6IFVpbnQ4QXJyYXksXG4gICkgPT4gdm9pZCxcbikge1xuICByZXR1cm4gbmV3IFBhY2tldEFjY3VtdWxhdG9yKChzbGljZXM6IFVpbnQ4QXJyYXlbXSkgPT4ge1xuICAgIGlmIChzbGljZXMubGVuZ3RoICE9PSA0KSB7XG4gICAgICBjb25zb2xlLmVycm9yKGBFeHBlY3RlZCA0IHNsaWNlcywgZ290ICR7c2xpY2VzLmxlbmd0aH1gKVxuICAgICAgcmV0dXJuXG4gICAgfVxuXG4gICAgLy8gQ3JlYXRlIHR5cGVkIHZpZXdzIGRpcmVjdGx5IG9uIHRoZSBzbGljZSBidWZmZXJzXG4gICAgLy8gU2xpY2UgMDogUG9pbnRzIChWZWMyID0gaTE2IHBhaXJzKVxuICAgIGNvbnN0IHBvaW50cyA9IG5ldyBJbnQxNkFycmF5KFxuICAgICAgc2xpY2VzWzBdLmJ1ZmZlcixcbiAgICAgIHNsaWNlc1swXS5ieXRlT2Zmc2V0LFxuICAgICAgc2xpY2VzWzBdLmJ5dGVMZW5ndGggLyAyLFxuICAgIClcblxuICAgIC8vIFNsaWNlIDE6IFJHQnMgKHJhdyBieXRlcylcbiAgICBjb25zdCByZ2JzID0gc2xpY2VzWzFdXG5cbiAgICAvLyBTbGljZSAyOiBUYWdzIChyYXcgYnl0ZXMgZm9yIG5vdywgY291bGQgYmUgdTE2KVxuICAgIGNvbnN0IHRhZ3MgPSBuZXcgVWludDE2QXJyYXkoXG4gICAgICBzbGljZXNbMl0uYnVmZmVyLFxuICAgICAgc2xpY2VzWzJdLmJ5dGVPZmZzZXQsXG4gICAgICBzbGljZXNbMl0uYnl0ZUxlbmd0aCAvIDIsXG4gICAgKVxuXG4gICAgLy8gU2xpY2UgMzogQ29tbWFuZCBkYXRhIChyYXcgYnl0ZXMpXG4gICAgY29uc3QgZGF0YSA9IHNsaWNlc1szXVxuXG4gICAgb25GcmFtZShwb2ludHMsIHJnYnMsIHRhZ3MsIGRhdGEpXG4gIH0pXG59XG5cbi8vIENvbW1hbmQgdGFnIGVudW0gbWF0Y2hpbmcgWmlnXG5lbnVtIENvbW1hbmRUYWcge1xuICBGaWxsUmVjdCA9IDAsXG4gIENsZWFyUmVjdCxcbiAgU2V0RmlsbFN0eWxlLFxuICBTZXRTdHJva2VTdHlsZSxcbiAgU2V0TGluZVdpZHRoLFxuICBCZWdpblBhdGgsXG4gIENsb3NlUGF0aCxcbiAgTW92ZVRvLFxuICBMaW5lVG8sXG4gIEFyY1RvLFxuICBCZXppZXJDdXJ2ZVRvLFxuICBGaWxsLFxuICBTdHJva2UsXG4gIFNhdmUsXG4gIFJlc3RvcmUsXG4gIFRyYW5zbGF0ZSxcbiAgUm90YXRlLFxuICBTY2FsZSxcbiAgQ3JlYXRlTGluZWFyR3JhZGllbnQsXG4gIEFkZENvbG9yU3RvcCxcbiAgU2V0RmlsbEdyYWRpZW50LFxuICBTZXRTdHJva2VHcmFkaWVudCxcbn1cblxuZXhwb3J0IGNsYXNzIENhbnZhc0RhdGFQcm9jZXNzb3Ige1xuICBwcml2YXRlIGNhbnZhc2VzOiAoQ2FudmFzUmVuZGVyaW5nQ29udGV4dDJEIHwgbnVsbClbXSA9IFtdXG4gIHByaXZhdGUgZ3JhZGllbnRzOiAoQ2FudmFzR3JhZGllbnQgfCBudWxsKVtdID0gW11cblxuICBhZGRDYW52YXMoY3R4OiBDYW52YXNSZW5kZXJpbmdDb250ZXh0MkQpOiBudW1iZXIge1xuICAgIGNvbnN0IHJlZiA9IHRoaXMuY2FudmFzZXMubGVuZ3RoXG4gICAgdGhpcy5jYW52YXNlcy5wdXNoKGN0eClcbiAgICB0aGlzLmdyYWRpZW50cy5wdXNoKG51bGwpXG4gICAgcmV0dXJuIHJlZlxuICB9XG5cbiAgcmVtb3ZlQ2FudmFzKHJlZjogbnVtYmVyKSB7XG4gICAgaWYgKHJlZiA+PSAwICYmIHJlZiA8IHRoaXMuY2FudmFzZXMubGVuZ3RoKSB7XG4gICAgICB0aGlzLmNhbnZhc2VzW3JlZl0gPSBudWxsXG4gICAgICB0aGlzLmdyYWRpZW50c1tyZWZdID0gbnVsbFxuICAgIH1cbiAgfVxuXG4gIC8vIFByb2Nlc3MgY29tcGxldGUgZnJhbWUgZnJvbSBtZXRhcGFja2V0XG4gIHByb2Nlc3NGcmFtZShcbiAgICBwb2ludHM6IEludDE2QXJyYXksXG4gICAgcmdiczogVWludDhBcnJheSxcbiAgICB0YWdzOiBVaW50MTZBcnJheSxcbiAgICBkYXRhOiBVaW50OEFycmF5LFxuICAgIGNhbnZhc1JlZjogbnVtYmVyID0gMCxcbiAgKSB7XG4gICAgLy8gQ3JlYXRlIGFjY2Vzc29ycyBmb3Igc3RydWN0dXJlZCBkYXRhXG4gICAgY29uc3QgcG9pbnRBY2Nlc3NvciA9IGNyZWF0ZVZlYzJBY2Nlc3Nvcihwb2ludHMpXG4gICAgY29uc3QgcmdiQWNjZXNzb3IgPSBjcmVhdGVSZ2JBY2Nlc3NvcihyZ2JzKVxuXG4gICAgY29uc3QgY3R4ID0gdGhpcy5jYW52YXNlc1tjYW52YXNSZWZdXG4gICAgaWYgKCFjdHgpIHtcbiAgICAgIGNvbnNvbGUud2FybihgQ2FudmFzICR7Y2FudmFzUmVmfSBub3QgZm91bmRgKVxuICAgICAgcmV0dXJuXG4gICAgfVxuXG4gICAgLy8gUHJvY2VzcyBjb21tYW5kcyB1c2luZyB0aGUgdHlwZWQgYXJyYXlzXG4gICAgY29uc3QgZGF0YVZpZXcgPSBuZXcgRGF0YVZpZXcoXG4gICAgICBkYXRhLmJ1ZmZlcixcbiAgICAgIGRhdGEuYnl0ZU9mZnNldCxcbiAgICAgIGRhdGEuYnl0ZUxlbmd0aCxcbiAgICApXG4gICAgbGV0IGRhdGFQb3MgPSAwXG5cbiAgICBmb3IgKGxldCBpID0gMDsgaSA8IHRhZ3MubGVuZ3RoOyBpKyspIHtcbiAgICAgIGNvbnN0IHRhZyA9IHRhZ3NbaV1cbiAgICAgIHRoaXMuZXhlY3V0ZUNvbW1hbmQoXG4gICAgICAgIGN0eCxcbiAgICAgICAgdGFnLFxuICAgICAgICBkYXRhVmlldyxcbiAgICAgICAgZGF0YVBvcyxcbiAgICAgICAgcG9pbnRBY2Nlc3NvcixcbiAgICAgICAgcmdiQWNjZXNzb3IsXG4gICAgICAgIGNhbnZhc1JlZixcbiAgICAgIClcblxuICAgICAgLy8gQWR2YW5jZSBkYXRhUG9zIGJhc2VkIG9uIGNvbW1hbmQgdHlwZVxuICAgICAgZGF0YVBvcyArPSB0aGlzLmdldENvbW1hbmREYXRhU2l6ZSh0YWcpXG4gICAgfVxuICB9XG5cbiAgcHJpdmF0ZSBnZXRDb21tYW5kRGF0YVNpemUodGFnOiBDb21tYW5kVGFnKTogbnVtYmVyIHtcbiAgICAvLyBGaXhlZC1zaXplIHVuaW9uIHBheWxvYWQ6IDggYnl0ZXMgKGZvdXIgdTE2cykgcGVyIGNvbW1hbmQuXG4gICAgLy8gTWF0Y2hlcyBaaWcgTXVsdGlBcnJheUxpc3QoQ29tbWFuZCkgc2VyaWFsaXphdGlvbi5cbiAgICByZXR1cm4gOFxuICB9XG5cbiAgcHJpdmF0ZSBleGVjdXRlQ29tbWFuZChcbiAgICBjdHg6IENhbnZhc1JlbmRlcmluZ0NvbnRleHQyRCxcbiAgICB0YWc6IENvbW1hbmRUYWcsXG4gICAgZGF0YVZpZXc6IERhdGFWaWV3LFxuICAgIGRhdGFQb3M6IG51bWJlcixcbiAgICBwb2ludEFjY2Vzc29yOiBSZXR1cm5UeXBlPHR5cGVvZiBjcmVhdGVWZWMyQWNjZXNzb3I+LFxuICAgIHJnYkFjY2Vzc29yOiBSZXR1cm5UeXBlPHR5cGVvZiBjcmVhdGVSZ2JBY2Nlc3Nvcj4sXG4gICAgY2FudmFzUmVmOiBudW1iZXIsXG4gICkge1xuICAgIC8vIHBlcmY6IGF2b2lkIGZyYW1lLWxvZ2dpbmcgaW5zaWRlIHRoZSBob3QgbG9vcFxuICAgIHN3aXRjaCAodGFnKSB7XG4gICAgICBjYXNlIENvbW1hbmRUYWcuRmlsbFJlY3Q6XG4gICAgICBjYXNlIENvbW1hbmRUYWcuQ2xlYXJSZWN0OiB7XG4gICAgICAgIGNvbnN0IHAxSWR4ID0gZGF0YVZpZXcuZ2V0VWludDE2KGRhdGFQb3MsIHRydWUpXG4gICAgICAgIGNvbnN0IHAySWR4ID0gZGF0YVZpZXcuZ2V0VWludDE2KGRhdGFQb3MgKyAyLCB0cnVlKVxuXG4gICAgICAgIGNvbnN0IHAxID0gcG9pbnRBY2Nlc3Nvci5nZXQocDFJZHgpXG4gICAgICAgIGNvbnN0IHAyID0gcG9pbnRBY2Nlc3Nvci5nZXQocDJJZHgpXG4gICAgICAgIGNvbnN0IHcgPSBwMi54IC0gcDEueFxuICAgICAgICBjb25zdCBoID0gcDIueSAtIHAxLnlcblxuICAgICAgICBpZiAodGFnID09PSBDb21tYW5kVGFnLkZpbGxSZWN0KSB7XG4gICAgICAgICAgY3R4LmZpbGxSZWN0KHAxLngsIHAxLnksIHcsIGgpXG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgY3R4LmNsZWFyUmVjdChwMS54LCBwMS55LCB3LCBoKVxuICAgICAgICB9XG4gICAgICAgIGJyZWFrXG4gICAgICB9XG5cbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5TZXRGaWxsU3R5bGU6XG4gICAgICBjYXNlIENvbW1hbmRUYWcuU2V0U3Ryb2tlU3R5bGU6IHtcbiAgICAgICAgY29uc3QgcmdiSWR4ID0gZGF0YVZpZXcuZ2V0VWludDE2KGRhdGFQb3MsIHRydWUpXG4gICAgICAgIGNvbnN0IGFscGhhVTE2ID0gZGF0YVZpZXcuZ2V0VWludDE2KGRhdGFQb3MgKyAyLCB0cnVlKVxuXG4gICAgICAgIC8vIENvbnZlcnQgZjE2IHRvIGYzMiAoc2ltcGxpZmllZCAtIHByb3BlciBmMTYgY29udmVyc2lvbiBuZWVkZWQpXG4gICAgICAgIGNvbnN0IGFscGhhID0gYWxwaGFVMTYgLyA2NTUzNVxuXG4gICAgICAgIGNvbnN0IHJnYiA9IHJnYkFjY2Vzc29yLmdldChyZ2JJZHgpXG4gICAgICAgIGNvbnN0IGNvbG9yID0gYHJnYmEoJHtyZ2Iucn0sICR7cmdiLmd9LCAke3JnYi5ifSwgJHthbHBoYX0pYFxuXG4gICAgICAgIGlmICh0YWcgPT09IENvbW1hbmRUYWcuU2V0RmlsbFN0eWxlKSB7XG4gICAgICAgICAgLy9jb25zb2xlLmxvZyhgU2V0dGluZyBmaWxsIHN0eWxlIHRvICR7Y29sb3J9YClcbiAgICAgICAgICBjdHguZmlsbFN0eWxlID0gY29sb3JcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAvLyBjb25zb2xlLmxvZyhgU2V0dGluZyBzdHJva2Ugc3R5bGUgdG8gJHtjb2xvcn1gKVxuICAgICAgICAgIGN0eC5zdHJva2VTdHlsZSA9IGNvbG9yXG4gICAgICAgIH1cbiAgICAgICAgYnJlYWtcbiAgICAgIH1cblxuICAgICAgY2FzZSBDb21tYW5kVGFnLk1vdmVUbzpcbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5MaW5lVG86IHtcbiAgICAgICAgY29uc3QgcG9pbnRJZHggPSBkYXRhVmlldy5nZXRVaW50MTYoZGF0YVBvcywgdHJ1ZSlcblxuICAgICAgICBjb25zdCBwb2ludCA9IHBvaW50QWNjZXNzb3IuZ2V0KHBvaW50SWR4KVxuICAgICAgICBpZiAodGFnID09PSBDb21tYW5kVGFnLk1vdmVUbykge1xuICAgICAgICAgIC8vIG5vIHBlci1mcmFtZSBsb2dnaW5nXG4gICAgICAgICAgY3R4Lm1vdmVUbyhwb2ludC54LCBwb2ludC55KVxuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgIC8vIGNvbnNvbGUubG9nKFxuICAgICAgICAgIC8vICAgYERyYXdpbmcgbGluZSB0byAoJHtwb2ludC54fSwgJHtwb2ludC55fSkgKGlkeCAke3BvaW50SWR4fSlgLFxuICAgICAgICAgIC8vIClcbiAgICAgICAgICBjdHgubGluZVRvKHBvaW50LngsIHBvaW50LnkpXG4gICAgICAgIH1cbiAgICAgICAgYnJlYWtcbiAgICAgIH1cblxuICAgICAgY2FzZSBDb21tYW5kVGFnLkFyY1RvOiB7XG4gICAgICAgIGNvbnN0IHAxSWR4ID0gZGF0YVZpZXcuZ2V0VWludDE2KGRhdGFQb3MsIHRydWUpXG4gICAgICAgIGNvbnN0IHAySWR4ID0gZGF0YVZpZXcuZ2V0VWludDE2KGRhdGFQb3MgKyAyLCB0cnVlKVxuICAgICAgICBjb25zdCByYWRpdXNVMTYgPSBkYXRhVmlldy5nZXRVaW50MTYoZGF0YVBvcyArIDQsIHRydWUpXG5cbiAgICAgICAgY29uc3QgcDEgPSBwb2ludEFjY2Vzc29yLmdldChwMUlkeClcbiAgICAgICAgY29uc3QgcDIgPSBwb2ludEFjY2Vzc29yLmdldChwMklkeClcbiAgICAgICAgY29uc3QgcmFkaXVzID0gcmFkaXVzVTE2XG5cbiAgICAgICAgLy8gY29uc29sZS5sb2coXG4gICAgICAgIC8vICAgYERyYXdpbmcgYXJjIGZyb20gKCR7cDEueH0sICR7cDEueX0pIHRvICgke3AyLnh9LCAke3AyLnl9KSB3aXRoIHJhZGl1cyAke3JhZGl1c31gLFxuICAgICAgICAvLyApXG4gICAgICAgIGN0eC5hcmNUbyhwMS54LCBwMS55LCBwMi54LCBwMi55LCByYWRpdXMpXG4gICAgICAgIGJyZWFrXG4gICAgICB9XG5cbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5CZXppZXJDdXJ2ZVRvOiB7XG4gICAgICAgIGNvbnN0IGNwMUlkeCA9IGRhdGFWaWV3LmdldFVpbnQxNihkYXRhUG9zLCB0cnVlKVxuICAgICAgICBjb25zdCBjcDJJZHggPSBkYXRhVmlldy5nZXRVaW50MTYoZGF0YVBvcyArIDIsIHRydWUpXG4gICAgICAgIGNvbnN0IGVuZElkeCA9IGRhdGFWaWV3LmdldFVpbnQxNihkYXRhUG9zICsgNCwgdHJ1ZSlcblxuICAgICAgICBjb25zdCBjcDEgPSBwb2ludEFjY2Vzc29yLmdldChjcDFJZHgpXG4gICAgICAgIGNvbnN0IGNwMiA9IHBvaW50QWNjZXNzb3IuZ2V0KGNwMklkeClcbiAgICAgICAgY29uc3QgZW5kID0gcG9pbnRBY2Nlc3Nvci5nZXQoZW5kSWR4KVxuXG4gICAgICAgIC8vIGNvbnNvbGUubG9nKFxuICAgICAgICAvLyAgIGBEcmF3aW5nIGJlemllciBjdXJ2ZSBmcm9tICgke2NwMS54fSwgJHtjcDEueX0pIHRvICgke2NwMi54fSwgJHtjcDIueX0pIHdpdGggY29udHJvbCBwb2ludHMgKCR7Y3AxLnh9LCAke2NwMS55fSkgYW5kICgke2NwMi54fSwgJHtjcDIueX0pYCxcbiAgICAgICAgLy8gKVxuICAgICAgICBjdHguYmV6aWVyQ3VydmVUbyhjcDEueCwgY3AxLnksIGNwMi54LCBjcDIueSwgZW5kLngsIGVuZC55KVxuICAgICAgICBicmVha1xuICAgICAgfVxuXG4gICAgICBjYXNlIENvbW1hbmRUYWcuU2V0TGluZVdpZHRoOiB7XG4gICAgICAgIGNvbnN0IHdpZHRoVTE2ID0gZGF0YVZpZXcuZ2V0VWludDE2KGRhdGFQb3MsIHRydWUpXG5cbiAgICAgICAgY29uc3Qgd2lkdGggPSB3aWR0aFUxNlxuICAgICAgICAvL2NvbnNvbGUubG9nKGBTZXR0aW5nIGxpbmUgd2lkdGggdG8gJHt3aWR0aH1gKVxuICAgICAgICBjdHgubGluZVdpZHRoID0gd2lkdGhcbiAgICAgICAgYnJlYWtcbiAgICAgIH1cblxuICAgICAgY2FzZSBDb21tYW5kVGFnLlRyYW5zbGF0ZTpcbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5TY2FsZToge1xuICAgICAgICBjb25zdCB2ZWNJZHggPSBkYXRhVmlldy5nZXRVaW50MTYoZGF0YVBvcywgdHJ1ZSlcblxuICAgICAgICBjb25zdCB2ZWMgPSBwb2ludEFjY2Vzc29yLmdldCh2ZWNJZHgpXG4gICAgICAgIGlmICh0YWcgPT09IENvbW1hbmRUYWcuVHJhbnNsYXRlKSB7XG4gICAgICAgICAgLy9jb25zb2xlLmxvZyhgVHJhbnNsYXRpbmcgY2FudmFzIGJ5ICgke3ZlYy54fSwgJHt2ZWMueX0pYClcbiAgICAgICAgICBjdHgudHJhbnNsYXRlKHZlYy54LCB2ZWMueSlcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAvLyBPdXIgcHJvdG9jb2wgZW5jb2RlcyBzY2FsZSBmYWN0b3JzIGFzIGkxNiBpbnRlZ2Vyc1xuICAgICAgICAgIC8vICgxLCAtMSkgZm9yIG1pcnJvcmluZy5cbiAgICAgICAgICBjdHguc2NhbGUodmVjLngsIHZlYy55KVxuICAgICAgICB9XG4gICAgICAgIGJyZWFrXG4gICAgICB9XG5cbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5Sb3RhdGU6IHtcbiAgICAgICAgY29uc3QgYW5nbGUgPSBkYXRhVmlldy5nZXRGbG9hdDMyKGRhdGFQb3MsIHRydWUpXG4gICAgICAgIGN0eC5yb3RhdGUoYW5nbGUpXG4gICAgICAgIGJyZWFrXG4gICAgICB9XG5cbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5DcmVhdGVMaW5lYXJHcmFkaWVudDoge1xuICAgICAgICBjb25zdCBwMUlkeCA9IGRhdGFWaWV3LmdldFVpbnQxNihkYXRhUG9zLCB0cnVlKVxuICAgICAgICBjb25zdCBwMklkeCA9IGRhdGFWaWV3LmdldFVpbnQxNihkYXRhUG9zICsgMiwgdHJ1ZSlcblxuICAgICAgICBjb25zdCBwMSA9IHBvaW50QWNjZXNzb3IuZ2V0KHAxSWR4KVxuICAgICAgICBjb25zdCBwMiA9IHBvaW50QWNjZXNzb3IuZ2V0KHAySWR4KVxuXG4gICAgICAgIGNvbnN0IGdyYWRpZW50ID0gY3R4LmNyZWF0ZUxpbmVhckdyYWRpZW50KHAxLngsIHAxLnksIHAyLngsIHAyLnkpXG4gICAgICAgIHRoaXMuZ3JhZGllbnRzW2NhbnZhc1JlZl0gPSBncmFkaWVudFxuICAgICAgICAvLyBjb25zb2xlLmxvZyhcbiAgICAgICAgLy8gICBgQ3JlYXRlZCBsaW5lYXIgZ3JhZGllbnQgZnJvbSAoJHtwMS54fSwgJHtwMS55fSkgdG8gKCR7cDIueH0sICR7cDIueX0pYCxcbiAgICAgICAgLy8gKVxuICAgICAgICBicmVha1xuICAgICAgfVxuXG4gICAgICBjYXNlIENvbW1hbmRUYWcuQWRkQ29sb3JTdG9wOiB7XG4gICAgICAgIGNvbnN0IHBvc2l0aW9uVTE2ID0gZGF0YVZpZXcuZ2V0VWludDE2KGRhdGFQb3MsIHRydWUpXG4gICAgICAgIGNvbnN0IHJnYklkeCA9IGRhdGFWaWV3LmdldFVpbnQxNihkYXRhUG9zICsgMiwgdHJ1ZSlcblxuICAgICAgICBjb25zdCBwb3NpdGlvbiA9IHBvc2l0aW9uVTE2IC8gNjU1MzUuMFxuICAgICAgICBjb25zdCByZ2IgPSByZ2JBY2Nlc3Nvci5nZXQocmdiSWR4KVxuXG4gICAgICAgIGNvbnN0IGdyYWRpZW50ID0gdGhpcy5ncmFkaWVudHNbY2FudmFzUmVmXVxuICAgICAgICBpZiAoZ3JhZGllbnQpIHtcbiAgICAgICAgICAvLyBjb25zb2xlLmxvZyhcbiAgICAgICAgICAvLyAgIGBBZGRpbmcgY29sb3Igc3RvcCBhdCBwb3NpdGlvbiAke3Bvc2l0aW9ufSB3aXRoIGNvbG9yICR7cmdiLnJ9LCAke3JnYi5nfSwgJHtyZ2IuYn1gLFxuICAgICAgICAgIC8vIClcbiAgICAgICAgICBncmFkaWVudC5hZGRDb2xvclN0b3AoXG4gICAgICAgICAgICBwb3NpdGlvbixcbiAgICAgICAgICAgIGByZ2JhKCR7cmdiLnJ9LCAke3JnYi5nfSwgJHtyZ2IuYn0sIDEuMClgLFxuICAgICAgICAgIClcbiAgICAgICAgfVxuICAgICAgICBicmVha1xuICAgICAgfVxuXG4gICAgICBjYXNlIENvbW1hbmRUYWcuU2V0RmlsbEdyYWRpZW50OiB7XG4gICAgICAgIGNvbnN0IGdyYWRpZW50ID0gdGhpcy5ncmFkaWVudHNbY2FudmFzUmVmXVxuXG4gICAgICAgIGlmIChncmFkaWVudCkge1xuICAgICAgICAgIC8vY29uc29sZS5sb2coXCJTZXR0aW5nIGZpbGwgZ3JhZGllbnQgdG9cIiwgZ3JhZGllbnQpXG4gICAgICAgICAgY3R4LmZpbGxTdHlsZSA9IGdyYWRpZW50XG4gICAgICAgIH1cbiAgICAgICAgYnJlYWtcbiAgICAgIH1cblxuICAgICAgY2FzZSBDb21tYW5kVGFnLlNldFN0cm9rZUdyYWRpZW50OiB7XG4gICAgICAgIGNvbnN0IGdyYWRpZW50ID0gdGhpcy5ncmFkaWVudHNbY2FudmFzUmVmXVxuICAgICAgICBpZiAoZ3JhZGllbnQpIHtcbiAgICAgICAgICAvL2NvbnNvbGUubG9nKFwiU2V0dGluZyBzdHJva2UgZ3JhZGllbnQgdG9cIiwgZ3JhZGllbnQpXG4gICAgICAgICAgY3R4LnN0cm9rZVN0eWxlID0gZ3JhZGllbnRcbiAgICAgICAgfVxuICAgICAgICBicmVha1xuICAgICAgfVxuXG4gICAgICBjYXNlIENvbW1hbmRUYWcuQmVnaW5QYXRoOlxuICAgICAgICBjdHguYmVnaW5QYXRoKClcbiAgICAgICAgYnJlYWtcblxuICAgICAgY2FzZSBDb21tYW5kVGFnLkNsb3NlUGF0aDpcbiAgICAgICAgY3R4LmNsb3NlUGF0aCgpXG4gICAgICAgIGJyZWFrXG5cbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5GaWxsOlxuICAgICAgICAvLyBjb25zb2xlLmxvZyhcIkZpbGxpbmcgY2FudmFzXCIpXG4gICAgICAgIGN0eC5maWxsKClcbiAgICAgICAgYnJlYWtcblxuICAgICAgY2FzZSBDb21tYW5kVGFnLlN0cm9rZTpcbiAgICAgICAgLy8gY29uc29sZS5sb2coXCJTdHJva2luZyBjYW52YXNcIilcbiAgICAgICAgY3R4LnN0cm9rZSgpXG4gICAgICAgIGJyZWFrXG5cbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5TYXZlOlxuICAgICAgICAvL2NvbnNvbGUubG9nKFwiU2F2aW5nIGNhbnZhcyBzdGF0ZVwiKVxuICAgICAgICBjdHguc2F2ZSgpXG4gICAgICAgIGJyZWFrXG5cbiAgICAgIGNhc2UgQ29tbWFuZFRhZy5SZXN0b3JlOlxuICAgICAgICAvL2NvbnNvbGUubG9nKFwiUmVzdG9yaW5nIGNhbnZhcyBzdGF0ZVwiKVxuICAgICAgICBjdHgucmVzdG9yZSgpXG4gICAgICAgIGJyZWFrXG5cbiAgICAgIGRlZmF1bHQ6XG4gICAgICAgIGNvbnNvbGUud2FybihgVW5rbm93biBjb21tYW5kIHRhZzogJHt0YWd9YClcbiAgICB9XG4gIH1cblxuICAvLyBQcm9jZXNzIGRhdGEtb3JpZW50ZWQgY29tbWFuZCBidWZmZXIgKG9sZCBpbnRlcmZhY2UgZm9yIGNvbXBhdGliaWxpdHkpXG4gIGV4ZWN1dGVDb21tYW5kcyhcbiAgICBidWZmZXI6IEFycmF5QnVmZmVyLFxuICAgIGxlbmd0aDogbnVtYmVyLFxuICAgIGNhbnZhc1JlZjogbnVtYmVyID0gMCxcbiAgKSB7XG4gICAgLy8gVGhpcyBpcyBub3cgaGFuZGxlZCBieSBwYWNrZXQgYWNjdW11bGF0b3IgYW5kIHByb2Nlc3NGcmFtZVxuICAgIGNvbnNvbGUud2FybihcbiAgICAgIFwiZXhlY3V0ZUNvbW1hbmRzIGNhbGxlZCBkaXJlY3RseSAtIHNob3VsZCB1c2UgcGFja2V0IGFjY3VtdWxhdG9yXCIsXG4gICAgKVxuICB9XG59XG5cbi8vIEZhY3RvcnkgZnVuY3Rpb24gZm9yIFdBU0kgaW50ZWdyYXRpb24gd2l0aCBwYWNrZXQgYWNjdW11bGF0b3JcbmV4cG9ydCBmdW5jdGlvbiBjcmVhdGVDYW52YXNEYXRhUHJvY2Vzc29yKCk6IHtcbiAgcHJvY2Vzc29yOiBDYW52YXNEYXRhUHJvY2Vzc29yXG4gIGFjY3VtdWxhdG9yOiBQYWNrZXRBY2N1bXVsYXRvclxufSB7XG4gIGNvbnN0IHByb2Nlc3NvciA9IG5ldyBDYW52YXNEYXRhUHJvY2Vzc29yKClcblxuICAvLyBDcmVhdGUgcGFja2V0IGFjY3VtdWxhdG9yIHRoYXQgZGlyZWN0bHkgcHJvdmlkZXMgc2xpY2VzXG4gIGNvbnN0IGFjY3VtdWxhdG9yID0gY3JlYXRlQ2FudmFzUGFja2V0SGFuZGxlcihcbiAgICAocG9pbnRzLCByZ2JzLCB0YWdzLCBkYXRhKSA9PiB7XG4gICAgICAvLyBQcm9jZXNzIHRoZSBmcmFtZSB3aXRoIGRlZmF1bHQgY2FudmFzICgwKVxuICAgICAgcHJvY2Vzc29yLnByb2Nlc3NGcmFtZShwb2ludHMsIHJnYnMsIHRhZ3MsIGRhdGEsIDApXG4gICAgfSxcbiAgKVxuXG4gIHJldHVybiB7XG4gICAgcHJvY2Vzc29yLFxuICAgIGFjY3VtdWxhdG9yLFxuICB9XG59XG4iLAogICAgImNvbnN0IFdBU0lfRVNVQ0NFU1MgPSAwXG5jb25zdCBXQVNJX1NURE9VVF9GSUxFTk8gPSAxXG5jb25zdCBXQVNJX1NUREVSUl9GSUxFTk8gPSAyXG5jb25zdCBDQU5WQVNfRklMRU5PID0gMyAvLyBDYW52YXMgaXMganVzdCBmZCAzIVxuXG5jb25zdCBDTE9DSyA9IHtcbiAgUkVBTFRJTUU6IDAsXG4gIE1PTk9UT05JQzogMSxcbiAgUFJPQ0VTU19DUFVUSU1FX0lEOiAyLFxuICBUSFJFQURfQ1BVVElNRV9JRDogMyxcbn1cblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgV0FTSSB7XG4gIG1lbW9yeTogV2ViQXNzZW1ibHkuTWVtb3J5IHwgbnVsbCA9IG51bGxcbiAgYnVmZmVyczogUmVjb3JkPG51bWJlciwgVWludDhBcnJheVtdPlxuICBjYW52YXNQcm9jZXNzb3I6ICgoYnVmZmVyOiBBcnJheUJ1ZmZlciwgbGVuZ3RoOiBudW1iZXIpID0+IHZvaWQpIHwgbnVsbCA9XG4gICAgbnVsbFxuXG4gIGNvbnN0cnVjdG9yKCkge1xuICAgIHRoaXMuYnVmZmVycyA9IHtcbiAgICAgIFtXQVNJX1NURE9VVF9GSUxFTk9dOiBbXSxcbiAgICAgIFtXQVNJX1NUREVSUl9GSUxFTk9dOiBbXSxcbiAgICAgIFtDQU5WQVNfRklMRU5PXTogW10sXG4gICAgfVxuICB9XG5cbiAgc2V0Q2FudmFzUHJvY2Vzc29yKFxuICAgIHByb2Nlc3NvcjogKGJ1ZmZlcjogQXJyYXlCdWZmZXIsIGxlbmd0aDogbnVtYmVyKSA9PiB2b2lkLFxuICApIHtcbiAgICB0aGlzLmNhbnZhc1Byb2Nlc3NvciA9IHByb2Nlc3NvclxuICB9XG5cbiAgc2V0TWVtb3J5KG1lbW9yeTogV2ViQXNzZW1ibHkuTWVtb3J5KSB7XG4gICAgdGhpcy5tZW1vcnkgPSBtZW1vcnlcbiAgfVxuXG4gIGdldERhdGFWaWV3KCk6IERhdGFWaWV3IHtcbiAgICBpZiAoIXRoaXMubWVtb3J5KSB7XG4gICAgICB0aHJvdyBuZXcgRXJyb3IoXCJNZW1vcnkgbm90IHNldFwiKVxuICAgIH1cbiAgICByZXR1cm4gbmV3IERhdGFWaWV3KHRoaXMubWVtb3J5LmJ1ZmZlcilcbiAgfVxuXG4gIGV4cG9ydHMoKSB7XG4gICAgcmV0dXJuIHtcbiAgICAgIHByb2NfZXhpdDogKGNvZGU6IG51bWJlcikgPT4ge1xuICAgICAgICBpZiAoY29kZSAhPT0gMCkge1xuICAgICAgICAgIGNvbnNvbGUud2FybihgW1dBU0ldIFByb2Nlc3MgZXhpdCB3aXRoIGNvZGUgJHtjb2RlfWApXG4gICAgICAgIH1cbiAgICAgIH0sXG5cbiAgICAgIGZkX3ByZXN0YXRfZ2V0OiAoKSA9PiB7XG4gICAgICAgIHJldHVybiA4IC8vIEVCQURGIC0gYmFkIGZpbGUgZGVzY3JpcHRvclxuICAgICAgfSxcblxuICAgICAgZmRfcHJlc3RhdF9kaXJfbmFtZTogKCkgPT4ge1xuICAgICAgICByZXR1cm4gMFxuICAgICAgfSxcblxuICAgICAgZmRfd3JpdGU6IChcbiAgICAgICAgZmQ6IG51bWJlcixcbiAgICAgICAgaW92czogbnVtYmVyLFxuICAgICAgICBpb3ZzTGVuOiBudW1iZXIsXG4gICAgICAgIG53cml0dGVuOiBudW1iZXIsXG4gICAgICApID0+IHtcbiAgICAgICAgLy8gbm8gZmQgd3JpdGUgbG9nZ2luZyBpbiBob3QgcGF0aFxuICAgICAgICBjb25zdCB2aWV3ID0gdGhpcy5nZXREYXRhVmlldygpXG4gICAgICAgIGxldCB3cml0dGVuID0gMFxuXG4gICAgICAgIGNvbnN0IGJ1ZmZlcnMgPSBBcnJheS5mcm9tKHsgbGVuZ3RoOiBpb3ZzTGVuIH0sIChfLCBpKSA9PiB7XG4gICAgICAgICAgY29uc3QgcHRyID0gaW92cyArIGkgKiA4XG4gICAgICAgICAgY29uc3QgYnVmID0gdmlldy5nZXRVaW50MzIocHRyLCB0cnVlKVxuICAgICAgICAgIGNvbnN0IGJ1ZkxlbiA9IHZpZXcuZ2V0VWludDMyKHB0ciArIDQsIHRydWUpXG5cbiAgICAgICAgICByZXR1cm4gbmV3IFVpbnQ4QXJyYXkodGhpcy5tZW1vcnkhLmJ1ZmZlciwgYnVmLCBidWZMZW4pXG4gICAgICAgIH0pXG5cbiAgICAgICAgLy8gU3BlY2lhbCBoYW5kbGluZyBmb3IgY2FudmFzIGZkXG4gICAgICAgIGlmIChmZCA9PT0gQ0FOVkFTX0ZJTEVOTykge1xuICAgICAgICAgIC8vIENhbnZhcyB3cml0ZXMgYXJlIGZyZXF1ZW50LCBvbmx5IGxvZyBpbiBkZWJ1ZyBtb2RlXG4gICAgICAgICAgLy8gY29uc29sZS5sb2coYFtXQVNJXSBDYW52YXMgd3JpdGU6ICR7YnVmZmVycy5yZWR1Y2UoKHN1bSwgYikgPT4gc3VtICsgYi5sZW5ndGgsIDApfSBieXRlc2ApXG5cbiAgICAgICAgICBpZiAodGhpcy5jYW52YXNQcm9jZXNzb3IpIHtcbiAgICAgICAgICAgIC8vIENvbWJpbmUgYWxsIGJ1ZmZlcnMgaW50byBvbmVcbiAgICAgICAgICAgIGNvbnN0IHRvdGFsTGVuZ3RoID0gYnVmZmVycy5yZWR1Y2UoKHN1bSwgYikgPT4gc3VtICsgYi5sZW5ndGgsIDApXG4gICAgICAgICAgICBjb25zdCBjb21iaW5lZCA9IG5ldyBVaW50OEFycmF5KHRvdGFsTGVuZ3RoKVxuICAgICAgICAgICAgbGV0IG9mZnNldCA9IDBcbiAgICAgICAgICAgIGZvciAoY29uc3QgYnVmIG9mIGJ1ZmZlcnMpIHtcbiAgICAgICAgICAgICAgY29tYmluZWQuc2V0KGJ1Ziwgb2Zmc2V0KVxuICAgICAgICAgICAgICBvZmZzZXQgKz0gYnVmLmxlbmd0aFxuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICAvLyBTZW5kIHRvIGNhbnZhcyBwcm9jZXNzb3JcbiAgICAgICAgICAgIHRoaXMuY2FudmFzUHJvY2Vzc29yKGNvbWJpbmVkLmJ1ZmZlciwgdG90YWxMZW5ndGgpXG4gICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGNvbnNvbGUud2FybihcIltXQVNJXSBDYW52YXMgd3JpdGUgYnV0IG5vIHByb2Nlc3NvciBzZXQhXCIpXG4gICAgICAgICAgfVxuXG4gICAgICAgICAgLy8gVXBkYXRlIHdyaXR0ZW4gY291bnRcbiAgICAgICAgICB3cml0dGVuID0gYnVmZmVycy5yZWR1Y2UoKHN1bSwgYikgPT4gc3VtICsgYi5sZW5ndGgsIDApXG4gICAgICAgICAgdmlldy5zZXRVaW50MzIobndyaXR0ZW4sIHdyaXR0ZW4sIHRydWUpXG4gICAgICAgICAgcmV0dXJuIFdBU0lfRVNVQ0NFU1NcbiAgICAgICAgfVxuXG4gICAgICAgIC8vIE5vcm1hbCBzdGRvdXQvc3RkZXJyIGhhbmRsaW5nXG4gICAgICAgIGZvciAoY29uc3QgaW92IG9mIGJ1ZmZlcnMpIHtcbiAgICAgICAgICBjb25zdCBuZXdsaW5lID0gMTAgLy8gJ1xcbidcbiAgICAgICAgICBsZXQgbGFzdEluZGV4ID0gMFxuXG4gICAgICAgICAgLy8gTG9vayBmb3IgbmV3bGluZXMgYW5kIGZsdXNoIGNvbXBsZXRlIGxpbmVzXG4gICAgICAgICAgZm9yIChsZXQgaSA9IDA7IGkgPCBpb3YubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIGlmIChpb3ZbaV0gPT09IG5ld2xpbmUpIHtcbiAgICAgICAgICAgICAgLy8gRm91bmQgYSBuZXdsaW5lLCBmbHVzaCB0aGUgYnVmZmVyZWQgY29udGVudCBwbHVzIHRoaXMgbGluZVxuICAgICAgICAgICAgICBjb25zdCBsaW5lQnl0ZXM6IFVpbnQ4QXJyYXlbXSA9IFtcbiAgICAgICAgICAgICAgICAuLi50aGlzLmJ1ZmZlcnNbZmRdLFxuICAgICAgICAgICAgICAgIGlvdi5zbGljZShsYXN0SW5kZXgsIGkpLFxuICAgICAgICAgICAgICBdXG5cbiAgICAgICAgICAgICAgLy8gQ29tYmluZSBhbGwgYnVmZmVycyBhbmQgZGVjb2RlXG4gICAgICAgICAgICAgIGxldCB0b3RhbExlbmd0aCA9IDBcbiAgICAgICAgICAgICAgZm9yIChjb25zdCBidWYgb2YgbGluZUJ5dGVzKSB7XG4gICAgICAgICAgICAgICAgdG90YWxMZW5ndGggKz0gYnVmLmxlbmd0aFxuICAgICAgICAgICAgICB9XG5cbiAgICAgICAgICAgICAgY29uc3QgY29tYmluZWQgPSBuZXcgVWludDhBcnJheSh0b3RhbExlbmd0aClcbiAgICAgICAgICAgICAgbGV0IG9mZnNldCA9IDBcbiAgICAgICAgICAgICAgZm9yIChjb25zdCBidWYgb2YgbGluZUJ5dGVzKSB7XG4gICAgICAgICAgICAgICAgY29tYmluZWQuc2V0KGJ1Ziwgb2Zmc2V0KVxuICAgICAgICAgICAgICAgIG9mZnNldCArPSBidWYubGVuZ3RoXG4gICAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgICBjb25zdCBsaW5lID0gbmV3IFRleHREZWNvZGVyKCkuZGVjb2RlKGNvbWJpbmVkKVxuXG4gICAgICAgICAgICAgIC8vIE91dHB1dCBiYXNlZCBvbiBmaWxlIGRlc2NyaXB0b3JcbiAgICAgICAgICAgICAgLy8gc3dhbGxvdyBzdGRvdXQvc3RkZXJyIHRvIGF2b2lkIHNwYW07IGNhbGxlciBjYW4gaG9vayBpZiBuZWVkZWRcblxuICAgICAgICAgICAgICAvLyBDbGVhciB0aGUgYnVmZmVyIGZvciB0aGlzIGZkXG4gICAgICAgICAgICAgIHRoaXMuYnVmZmVyc1tmZF0gPSBbXVxuICAgICAgICAgICAgICBsYXN0SW5kZXggPSBpICsgMVxuICAgICAgICAgICAgfVxuICAgICAgICAgIH1cblxuICAgICAgICAgIC8vIEJ1ZmZlciBhbnkgcmVtYWluaW5nIGJ5dGVzIHRoYXQgZG9uJ3QgZW5kIGluIG5ld2xpbmVcbiAgICAgICAgICBpZiAobGFzdEluZGV4IDwgaW92Lmxlbmd0aCkge1xuICAgICAgICAgICAgdGhpcy5idWZmZXJzW2ZkXS5wdXNoKGlvdi5zbGljZShsYXN0SW5kZXgpKVxuICAgICAgICAgIH1cblxuICAgICAgICAgIHdyaXR0ZW4gKz0gaW92LmJ5dGVMZW5ndGhcbiAgICAgICAgfVxuXG4gICAgICAgIHZpZXcuc2V0VWludDMyKG53cml0dGVuLCB3cml0dGVuLCB0cnVlKVxuICAgICAgICByZXR1cm4gV0FTSV9FU1VDQ0VTU1xuICAgICAgfSxcblxuICAgICAgZmRfY2xvc2U6ICgpID0+IHtcbiAgICAgICAgcmV0dXJuIDBcbiAgICAgIH0sXG5cbiAgICAgIGZkX3JlYWQ6ICgpID0+IHtcbiAgICAgICAgcmV0dXJuIDBcbiAgICAgIH0sXG5cbiAgICAgIGZkX3B3cml0ZTogKFxuICAgICAgICBmZDogbnVtYmVyLFxuICAgICAgICBpb3ZzOiBudW1iZXIsXG4gICAgICAgIGlvdnNMZW46IG51bWJlcixcbiAgICAgICAgb2Zmc2V0OiBiaWdpbnQsXG4gICAgICAgIG53cml0dGVuOiBudW1iZXIsXG4gICAgICApID0+IHtcbiAgICAgICAgaWYgKGZkICE9PSBDQU5WQVNfRklMRU5PKVxuICAgICAgICAgIGNvbnNvbGUubG9nKFwiZmRfcHdyaXRlXCIsIGZkLCBpb3ZzLCBpb3ZzTGVuLCBvZmZzZXQsIG53cml0dGVuKVxuICAgICAgICAvLyBGb3Igb3RoZXIgZmRzLCB3ZSBkb24ndCBzdXBwb3J0IHBvc2l0aW9uYWwgd3JpdGVzXG4gICAgICAgIGlmIChcbiAgICAgICAgICBmZCA9PT0gQ0FOVkFTX0ZJTEVOTyB8fFxuICAgICAgICAgIGZkID09PSBXQVNJX1NURE9VVF9GSUxFTk8gfHxcbiAgICAgICAgICBmZCA9PT0gV0FTSV9TVERFUlJfRklMRU5PXG4gICAgICAgICkge1xuICAgICAgICAgIC8vIEp1c3QgdXNlIHJlZ3VsYXIgd3JpdGUgZm9yIGNhbnZhcyAtIHdlIGFsd2F5cyBhcHBlbmRcbiAgICAgICAgICByZXR1cm4gdGhpcy5leHBvcnRzKCkuZmRfd3JpdGUoZmQsIGlvdnMsIGlvdnNMZW4sIG53cml0dGVuKVxuICAgICAgICB9XG4gICAgICAgIC8vIE5vdCBpbXBsZW1lbnRlZCBmb3Igb3RoZXIgZmRzXG4gICAgICAgIHJldHVybiA4IC8vIEVCQURGXG4gICAgICB9LFxuXG4gICAgICBmZF9zZWVrOiAoKSA9PiB7XG4gICAgICAgIHJldHVybiAwXG4gICAgICB9LFxuXG4gICAgICBmZF9mZHN0YXRfZ2V0OiAoKSA9PiB7XG4gICAgICAgIHJldHVybiAwXG4gICAgICB9LFxuXG4gICAgICBmZF9mZHN0YXRfc2V0X2ZsYWdzOiAoKSA9PiB7XG4gICAgICAgIHJldHVybiAwXG4gICAgICB9LFxuXG4gICAgICBwYXRoX29wZW46ICgpID0+IHtcbiAgICAgICAgcmV0dXJuIDggLy8gRUJBREZcbiAgICAgIH0sXG5cbiAgICAgIHBhdGhfcmVuYW1lOiAoKSA9PiB7XG4gICAgICAgIHJldHVybiAwXG4gICAgICB9LFxuXG4gICAgICBwYXRoX2NyZWF0ZV9kaXJlY3Rvcnk6ICgpID0+IHtcbiAgICAgICAgcmV0dXJuIDBcbiAgICAgIH0sXG5cbiAgICAgIHBhdGhfcmVtb3ZlX2RpcmVjdG9yeTogKCkgPT4ge1xuICAgICAgICByZXR1cm4gMFxuICAgICAgfSxcblxuICAgICAgcGF0aF91bmxpbmtfZmlsZTogKCkgPT4ge1xuICAgICAgICByZXR1cm4gMFxuICAgICAgfSxcblxuICAgICAgcGF0aF9maWxlc3RhdF9nZXQ6ICgpID0+IHtcbiAgICAgICAgcmV0dXJuIDBcbiAgICAgIH0sXG5cbiAgICAgIGZkX2ZpbGVzdGF0X2dldDogKCkgPT4ge1xuICAgICAgICByZXR1cm4gMFxuICAgICAgfSxcblxuICAgICAgcmFuZG9tX2dldDogKGJ1Zl9wdHI6IG51bWJlciwgYnVmX2xlbjogbnVtYmVyKSA9PiB7XG4gICAgICAgIGNvbnN0IGJ1ZmZlciA9IG5ldyBVaW50OEFycmF5KHRoaXMubWVtb3J5IS5idWZmZXIsIGJ1Zl9wdHIsIGJ1Zl9sZW4pXG4gICAgICAgIGNyeXB0by5nZXRSYW5kb21WYWx1ZXMoYnVmZmVyKVxuICAgICAgICByZXR1cm4gMFxuICAgICAgfSxcblxuICAgICAgY2xvY2tfdGltZV9nZXQ6IChcbiAgICAgICAgY2xvY2tfaWQ6IG51bWJlcixcbiAgICAgICAgcHJlY2lzaW9uOiBiaWdpbnQsXG4gICAgICAgIHRpbWVzdGFtcF9vdXQ6IG51bWJlcixcbiAgICAgICkgPT4ge1xuICAgICAgICBjb25zdCB2aWV3ID0gdGhpcy5nZXREYXRhVmlldygpXG5cbiAgICAgICAgc3dpdGNoIChjbG9ja19pZCkge1xuICAgICAgICAgIGNhc2UgQ0xPQ0suUkVBTFRJTUU6XG4gICAgICAgICAgY2FzZSBDTE9DSy5NT05PVE9OSUM6IHtcbiAgICAgICAgICAgIGNvbnN0IHQgPSBCaWdJbnQoRGF0ZS5ub3coKSkgKiBCaWdJbnQoMWU2KSAvLyBDb252ZXJ0IG1zIHRvIG5zXG4gICAgICAgICAgICB2aWV3LnNldEJpZ1VpbnQ2NCh0aW1lc3RhbXBfb3V0LCB0LCB0cnVlKVxuICAgICAgICAgICAgYnJlYWtcbiAgICAgICAgICB9XG5cbiAgICAgICAgICBjYXNlIENMT0NLLlBST0NFU1NfQ1BVVElNRV9JRDpcbiAgICAgICAgICBjYXNlIENMT0NLLlRIUkVBRF9DUFVUSU1FX0lEOiB7XG4gICAgICAgICAgICAvLyBVc2UgcGVyZm9ybWFuY2Uubm93KCkgZm9yIENQVSB0aW1lXG4gICAgICAgICAgICBjb25zdCB0ID0gQmlnSW50KE1hdGguZmxvb3IocGVyZm9ybWFuY2Uubm93KCkgKiAxZTYpKVxuICAgICAgICAgICAgdmlldy5zZXRCaWdVaW50NjQodGltZXN0YW1wX291dCwgdCwgdHJ1ZSlcbiAgICAgICAgICAgIGJyZWFrXG4gICAgICAgICAgfVxuXG4gICAgICAgICAgZGVmYXVsdDpcbiAgICAgICAgICAgIGNvbnNvbGUud2FybihgW1dBU0ldIFVuaGFuZGxlZCBjbG9jayB0eXBlOiAke2Nsb2NrX2lkfWApXG4gICAgICAgICAgICByZXR1cm4gMVxuICAgICAgICB9XG5cbiAgICAgICAgcmV0dXJuIDBcbiAgICAgIH0sXG5cbiAgICAgIGVudmlyb25fc2l6ZXNfZ2V0OiAoKSA9PiB7XG4gICAgICAgIHJldHVybiAwXG4gICAgICB9LFxuXG4gICAgICBlbnZpcm9uX2dldDogKCkgPT4ge1xuICAgICAgICByZXR1cm4gMFxuICAgICAgfSxcblxuICAgICAgYXJnc19zaXplc19nZXQ6ICgpID0+IHtcbiAgICAgICAgcmV0dXJuIDBcbiAgICAgIH0sXG5cbiAgICAgIGFyZ3NfZ2V0OiAoKSA9PiB7XG4gICAgICAgIHJldHVybiAwXG4gICAgICB9LFxuICAgIH1cbiAgfVxufVxuIiwKICAgICJpbXBvcnQgeyBjcmVhdGVDYW52YXNEYXRhUHJvY2Vzc29yIH0gZnJvbSBcIi4vY2FudmFzLWRhdGEtcHJvY2Vzc29yXCJcblxuaW1wb3J0IFdBU0kgZnJvbSBcIi4vd2FzaVwiXG5cbmV4cG9ydCBjbGFzcyBTcGVjdHJ1bVdhc20ge1xuICBwcml2YXRlIGluc3RhbmNlOiBXZWJBc3NlbWJseS5JbnN0YW5jZSB8IG51bGwgPSBudWxsXG4gIHByaXZhdGUgY2FudmFzZXM6IChDYW52YXNSZW5kZXJpbmdDb250ZXh0MkQgfCBudWxsKVtdID0gW11cbiAgcHJpdmF0ZSBncmFkaWVudHM6IChDYW52YXNHcmFkaWVudCB8IG51bGwpW10gPSBbXVxuICBwcml2YXRlIGRhdGFBcnJheTogVWludDhBcnJheTxBcnJheUJ1ZmZlcj4gfCBudWxsID0gbnVsbFxuICBwcml2YXRlIGRhdGFQcm9jZXNzb3I6IFJldHVyblR5cGU8dHlwZW9mIGNyZWF0ZUNhbnZhc0RhdGFQcm9jZXNzb3I+IHwgbnVsbCA9XG4gICAgbnVsbFxuICBwcml2YXRlIHdhc2k6IFdBU0kgfCBudWxsID0gbnVsbFxuICBwcml2YXRlIGN1cnJlbnRDYW52YXNSZWY6IG51bWJlciA9IDBcbiAgcHJpdmF0ZSBkYXRhRjMyOiBGbG9hdDMyQXJyYXk8QXJyYXlCdWZmZXI+IHwgbnVsbCA9IG51bGxcbiAgcHJpdmF0ZSBtb2RlOiBcImFyY1wiIHwgXCJiYXJzXCIgfCBcImFyY19zYWZlXCIgPSBcImFyY19zYWZlXCJcblxuICBhc3luYyBpbml0aWFsaXplKGNhbnZhczogSFRNTENhbnZhc0VsZW1lbnQsIGFuYWx5c2VyOiBBbmFseXNlck5vZGUpIHtcbiAgICBjb25zdCBjdHggPSBjYW52YXMuZ2V0Q29udGV4dChcIjJkXCIpIVxuXG4gICAgLy8gQWRkIHRoaXMgY2FudmFzIHRvIG91ciBhcnJheSBhbmQgZ2V0IGl0cyBpbmRleFxuICAgIGNvbnN0IGNhbnZhc1JlZiA9IHRoaXMuY2FudmFzZXMubGVuZ3RoXG4gICAgdGhpcy5jYW52YXNlcy5wdXNoKGN0eClcbiAgICB0aGlzLmdyYWRpZW50cy5wdXNoKG51bGwpXG5cbiAgICAvLyBJbml0aWFsaXplIFdBU0lcbiAgICB0aGlzLndhc2kgPSBuZXcgV0FTSSgpXG5cbiAgICAvLyBDcmVhdGUgaW1wb3J0cyBmb3IgY2FudmFzIGZ1bmN0aW9ucyAtIGFsbCBub3cgdGFrZSByZWYgYXMgZmlyc3QgcGFyYW1cbiAgICBjb25zdCBpbXBvcnRzID0ge1xuICAgICAgd2FzaV9zbmFwc2hvdF9wcmV2aWV3MTogdGhpcy53YXNpLmV4cG9ydHMoKSxcbiAgICAgIGVudjoge30sXG4gICAgfVxuXG4gICAgLy8gVXNlIHRoZSBkZWJ1ZyBzZXJ2aWNlIGZvciBzdGFibGUgVVJMcyBpbiBkZXZlbG9wbWVudFxuICAgIGNvbnN0IHsgaW5zdGFuY2UgfSA9IGF3YWl0IFdlYkFzc2VtYmx5Lmluc3RhbnRpYXRlU3RyZWFtaW5nKFxuICAgICAgZmV0Y2goXCJzcGVjdHJ1bS53YXNtXCIpLFxuICAgICAgaW1wb3J0cyxcbiAgICApXG5cbiAgICBpZiAoIWluc3RhbmNlKSB7XG4gICAgICB0aHJvdyBuZXcgRXJyb3IoXCJGYWlsZWQgdG8gaW5zdGFudGlhdGUgV0FTTSBtb2R1bGVcIilcbiAgICB9XG5cbiAgICB0aGlzLmluc3RhbmNlID0gaW5zdGFuY2VcblxuICAgIC8vIFNldCBtZW1vcnkgZm9yIFdBU0lcbiAgICBjb25zdCBtZW1vcnkgPSB0aGlzLmluc3RhbmNlLmV4cG9ydHMubWVtb3J5IGFzIFdlYkFzc2VtYmx5Lk1lbW9yeVxuICAgIHRoaXMud2FzaSEuc2V0TWVtb3J5KG1lbW9yeSlcblxuICAgIC8vIENyZWF0ZSB0aGUgZGF0YSBwcm9jZXNzb3Igd2l0aCBwYWNrZXQgYWNjdW11bGF0b3JcbiAgICB0aGlzLmRhdGFQcm9jZXNzb3IgPSBjcmVhdGVDYW52YXNEYXRhUHJvY2Vzc29yKClcblxuICAgIC8vIENvbm5lY3QgV0FTSSB0byBmZWVkIGRhdGEgdGhyb3VnaCB0aGUgcGFja2V0IGFjY3VtdWxhdG9yXG4gICAgdGhpcy53YXNpIS5zZXRDYW52YXNQcm9jZXNzb3IoKGJ1ZmZlcjogQXJyYXlCdWZmZXIsIGxlbmd0aDogbnVtYmVyKSA9PiB7XG4gICAgICAvLyBGZWVkIGNodW5rIHRvIHBhY2tldCBhY2N1bXVsYXRvclxuICAgICAgY29uc3QgdmFsaWREYXRhID0gbmV3IFVpbnQ4QXJyYXkoYnVmZmVyLCAwLCBsZW5ndGgpXG4gICAgICB0aGlzLmRhdGFQcm9jZXNzb3IhLmFjY3VtdWxhdG9yLmFkZENodW5rKFxuICAgICAgICB2YWxpZERhdGEuYnVmZmVyLnNsaWNlKFxuICAgICAgICAgIHZhbGlkRGF0YS5ieXRlT2Zmc2V0LFxuICAgICAgICAgIHZhbGlkRGF0YS5ieXRlT2Zmc2V0ICsgbGVuZ3RoLFxuICAgICAgICApLFxuICAgICAgKVxuICAgIH0pXG5cbiAgICAvLyBBZGQgdGhlIGNhbnZhcyB0byB0aGUgZGF0YSBwcm9jZXNzb3JcbiAgICB0aGlzLmRhdGFQcm9jZXNzb3IucHJvY2Vzc29yLmFkZENhbnZhcyhjdHgpXG4gICAgdGhpcy5jdXJyZW50Q2FudmFzUmVmID0gY2FudmFzUmVmXG5cbiAgICBjb25zdCBkZWJ1ZyA9IG5ldyBVUkwobG9jYXRpb24uaHJlZikuc2VhcmNoUGFyYW1zLmdldChcImRlYnVnXCIpID09PSBcIjFcIlxuICAgIC8vIE1vZGU6IGFsbG93ID9tb2RlPWJhcnMgdG8gZm9yY2UgdGhlIGxlZ2FjeSBzdGFibGUgcGF0aFxuICAgIGNvbnN0IG0gPSBuZXcgVVJMKGxvY2F0aW9uLmhyZWYpLnNlYXJjaFBhcmFtcy5nZXQoXCJtb2RlXCIpXG4gICAgaWYgKG0gPT09IFwiYmFyc1wiIHx8IG0gPT09IFwiYXJjX3NhZmVcIiB8fCBtID09PSBcImFyY1wiKSB0aGlzLm1vZGUgPSBtIGFzIGFueVxuXG4gICAgY29uc3QgY2FwdHVyZSA9IG5ldyBVUkwobG9jYXRpb24uaHJlZikuc2VhcmNoUGFyYW1zLmdldChcImNhcHR1cmVcIikgPT09IFwiMVwiXG5cbiAgICBpZiAoZGVidWcpIHtcbiAgICAgIGNvbnN0IHZlciA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KS5zcGVjdHJ1bV92ZXJzaW9uPy4oKSA/PyBcIj9cIlxuICAgICAgY29uc29sZS5sb2coXCJTcGVjdHJ1bVdBU00gdmVyc2lvbjpcIiwgdmVyKVxuICAgIH1cblxuICAgIGNvbnN0IF9pbml0ID0gdGhpcy5pbnN0YW5jZS5leHBvcnRzLl9pbml0aWFsaXplIGFzIEZ1bmN0aW9uXG4gICAgX2luaXQoKVxuXG4gICAgY29uc3QgaW5pdEZuID0gdGhpcy5pbnN0YW5jZS5leHBvcnRzLnNwZWN0cnVtX2luaXQgYXMgRnVuY3Rpb24gfCB1bmRlZmluZWRcbiAgICBpZiAoaW5pdEZuKSB7XG4gICAgICBpbml0Rm4oY2FudmFzUmVmKVxuICAgIH1cblxuICAgIC8vIFNldCBjYW52YXMgc2l6ZSBhbmQgYW5hbHlzZXIgZEIgcmFuZ2UgaW4gV0FTTVxuICAgIGNvbnN0IHNldFNpemUgPSB0aGlzLmluc3RhbmNlLmV4cG9ydHMuc3BlY3RydW1fc2V0X2NhbnZhc19zaXplIGFzIEZ1bmN0aW9uXG4gICAgc2V0U2l6ZShjYW52YXMud2lkdGgsIGNhbnZhcy5oZWlnaHQpXG5cbiAgICBjb25zdCBzZXREYiA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgLnNwZWN0cnVtX3NldF9kYl9yYW5nZSBhcyBGdW5jdGlvblxuICAgIGlmIChzZXREYikgc2V0RGIoYW5hbHlzZXIubWluRGVjaWJlbHMsIGFuYWx5c2VyLm1heERlY2liZWxzKVxuXG4gICAgLy8gUHJvdmlkZSBhdWRpbyBpbmZvIGFuZCBiYXNlbGluZSBwcm9jZXNzaW5nIHBhcmFtc1xuICAgIGNvbnN0IHNldEF1ZGlvID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAuc3BlY3RydW1fc2V0X2F1ZGlvX2luZm8gYXMgRnVuY3Rpb25cbiAgICBpZiAoc2V0QXVkaW8pIHNldEF1ZGlvKGFuYWx5c2VyLmNvbnRleHQuc2FtcGxlUmF0ZSwgYW5hbHlzZXIuZmZ0U2l6ZSlcblxuICAgIGNvbnN0IHNldEFnYyA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KS5zcGVjdHJ1bV9zZXRfYWdjIGFzIEZ1bmN0aW9uXG4gICAgaWYgKHNldEFnYykgc2V0QWdjKDAuNjUsIDAuMjUsIDAuOTUsIDAuNiwgMy41KVxuXG4gICAgY29uc3Qgc2V0Vm9jYWwgPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgIC5zcGVjdHJ1bV9zZXRfdm9jYWwgYXMgRnVuY3Rpb25cbiAgICBpZiAoc2V0Vm9jYWwpIHNldFZvY2FsKDI1MDAuMCwgMC45LCAwLjMpXG5cbiAgICAvLyBOZXcgcnVudGltZSB0dW5pbmcgdG8gcmVkdWNlIGJhc3MgYmlhcyBhbmQgc2hhcnBlbiBsZWFkIHJpYmJvblxuICAgIGNvbnN0IHNldE1hcCA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgLnNwZWN0cnVtX3NldF9tYXBwaW5nIGFzIEZ1bmN0aW9uXG4gICAgY29uc3Qgc2V0UHJlc2VuY2UgPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgIC5zcGVjdHJ1bV9zZXRfcHJlc2VuY2VfcmFuZ2UgYXMgRnVuY3Rpb25cbiAgICBjb25zdCBzZXRUcmFja1BhcmFtcyA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgLnNwZWN0cnVtX3NldF90cmFja19wYXJhbXMgYXMgRnVuY3Rpb25cblxuICAgIGlmICh0aGlzLm1vZGUgPT09IFwiYXJjXCIpIHtcbiAgICAgIC8vIFN0YXJ0IHBlcm1pc3NpdmUgc28gYXJjX2YzMiBuZXZlciBkcmF3cyBmbGF0OyBIVUQgY2FuIHRpZ2h0ZW4gbGF0ZXJcbiAgICAgIHNldE1hcD8uKDAuNiwgMTIwLjApXG4gICAgICBzZXRQcmVzZW5jZT8uKDIwMC4wLCA4MDAwLjApXG4gICAgICBzZXRUcmFja1BhcmFtcz8uKDYsIDEyLCAxMCwgMC4wLCAwLjAsIDApXG4gICAgfSBlbHNlIHtcbiAgICAgIC8vIFJlYXNvbmFibGUgZGVmYXVsdHMgZm9yIHNhZmUvbGVnYWN5IG1vZGVzXG4gICAgICBzZXRNYXA/LigwLjU1LCAyMjAuMClcbiAgICAgIHNldFByZXNlbmNlPy4oMTYwMC4wLCA1MjAwLjApXG4gICAgICBzZXRUcmFja1BhcmFtcz8uKDYsIDEyLCA4LCAwLjYsIDAuMTIsIDIpXG4gICAgfVxuXG4gICAgaWYgKGRlYnVnKSB7XG4gICAgICB0cnkge1xuICAgICAgICBsZXQgbGFzdCA9IDBcbiAgICAgICAgY29uc3QgZWwgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwiZGl2XCIpXG4gICAgICAgIGVsLnN0eWxlLnBvc2l0aW9uID0gXCJmaXhlZFwiXG4gICAgICAgIGVsLnN0eWxlLmJvdHRvbSA9IFwiOHB4XCJcbiAgICAgICAgZWwuc3R5bGUubGVmdCA9IFwiOHB4XCJcbiAgICAgICAgZWwuc3R5bGUucGFkZGluZyA9IFwiNHB4IDhweFwiXG4gICAgICAgIGVsLnN0eWxlLmJhY2tncm91bmQgPSBcInJnYmEoMCwwLDAsMC4zNSlcIlxuICAgICAgICBlbC5zdHlsZS5jb2xvciA9IFwiI2ZmZlwiXG4gICAgICAgIGVsLnN0eWxlLmZvbnQgPSBcIjEycHggdWktbW9ub3NwYWNlLCBtb25vc3BhY2VcIlxuICAgICAgICBlbC5zdHlsZS56SW5kZXggPSBcIjk5OTk5XCJcbiAgICAgICAgY29uc3QgbW9kZUxhYmVsID1cbiAgICAgICAgICB0aGlzLm1vZGUgPT09IFwiYmFyc1wiXG4gICAgICAgICAgICA/IFwiYmFyc191OFwiXG4gICAgICAgICAgICA6IHRoaXMubW9kZSA9PT0gXCJhcmNfc2FmZVwiXG4gICAgICAgICAgICA/IFwiYXJjX3U4XCJcbiAgICAgICAgICAgIDogXCJhcmNfZjMyK3RyYWNrc1wiXG4gICAgICAgIGVsLnRleHRDb250ZW50ID0gYHZpejogJHttb2RlTGFiZWx9YFxuICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKGVsKVxuICAgICAgICAvLyBTaW1wbGUgdHVuaW5nIHBhbmVsXG4gICAgICAgIGNvbnN0IHBhbmVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcImRpdlwiKVxuICAgICAgICBwYW5lbC5zdHlsZS5wb3NpdGlvbiA9IFwiZml4ZWRcIlxuICAgICAgICBwYW5lbC5zdHlsZS5ib3R0b20gPSBcIjhweFwiXG4gICAgICAgIHBhbmVsLnN0eWxlLnJpZ2h0ID0gXCI4cHhcIlxuICAgICAgICBwYW5lbC5zdHlsZS5wYWRkaW5nID0gXCI4cHhcIlxuICAgICAgICBwYW5lbC5zdHlsZS5iYWNrZ3JvdW5kID0gXCJyZ2JhKDAsMCwwLDAuMzUpXCJcbiAgICAgICAgcGFuZWwuc3R5bGUuY29sb3IgPSBcIiNmZmZcIlxuICAgICAgICBwYW5lbC5zdHlsZS5mb250ID0gXCIxMnB4IHVpLW1vbm9zcGFjZSwgbW9ub3NwYWNlXCJcbiAgICAgICAgcGFuZWwuc3R5bGUuekluZGV4ID0gXCI5OTk5OVwiXG4gICAgICAgIHBhbmVsLnN0eWxlLmRpc3BsYXkgPSBcImdyaWRcIlxuICAgICAgICBwYW5lbC5zdHlsZS5ncmlkVGVtcGxhdGVDb2x1bW5zID0gXCJhdXRvIGF1dG9cIlxuICAgICAgICBwYW5lbC5zdHlsZS5nYXAgPSBcIjZweCA4cHhcIlxuICAgICAgICBjb25zdCBhZGQgPSAobGFiZWw6IHN0cmluZywgaW5wdXQ6IEhUTUxJbnB1dEVsZW1lbnQpID0+IHtcbiAgICAgICAgICBjb25zdCBsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcImRpdlwiKVxuICAgICAgICAgIGwudGV4dENvbnRlbnQgPSBsYWJlbFxuICAgICAgICAgIHBhbmVsLmFwcGVuZENoaWxkKGwpXG4gICAgICAgICAgcGFuZWwuYXBwZW5kQ2hpbGQoaW5wdXQpXG4gICAgICAgIH1cbiAgICAgICAgY29uc3QgbWFrZSA9IChcbiAgICAgICAgICBtaW46IG51bWJlcixcbiAgICAgICAgICBtYXg6IG51bWJlcixcbiAgICAgICAgICBzdGVwOiBudW1iZXIsXG4gICAgICAgICAgdmFsOiBudW1iZXIsXG4gICAgICAgICAgY2I6ICh2OiBudW1iZXIpID0+IHZvaWQsXG4gICAgICAgICkgPT4ge1xuICAgICAgICAgIGNvbnN0IGkgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KFwiaW5wdXRcIilcbiAgICAgICAgICBpLnR5cGUgPSBcInJhbmdlXCJcbiAgICAgICAgICBpLm1pbiA9IFN0cmluZyhtaW4pXG4gICAgICAgICAgaS5tYXggPSBTdHJpbmcobWF4KVxuICAgICAgICAgIGkuc3RlcCA9IFN0cmluZyhzdGVwKVxuICAgICAgICAgIGkudmFsdWUgPSBTdHJpbmcodmFsKVxuICAgICAgICAgIGkub25pbnB1dCA9ICgpID0+IGNiKE51bWJlcihpLnZhbHVlKSlcbiAgICAgICAgICByZXR1cm4gaSBhcyBIVE1MSW5wdXRFbGVtZW50XG4gICAgICAgIH1cbiAgICAgICAgY29uc3Qgc2V0UHJlc2VuY2VSYW5nZSA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgICAgIC5zcGVjdHJ1bV9zZXRfcHJlc2VuY2VfcmFuZ2UgYXMgRnVuY3Rpb25cbiAgICAgICAgY29uc3Qgc2V0VHJhY2tQYXJhbXMgPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgICAgICAuc3BlY3RydW1fc2V0X3RyYWNrX3BhcmFtcyBhcyBGdW5jdGlvblxuICAgICAgICBjb25zdCBzZXRNYXBDZmcgPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgICAgICAuc3BlY3RydW1fc2V0X21hcHBpbmcgYXMgRnVuY3Rpb25cbiAgICAgICAgYWRkKFxuICAgICAgICAgIFwicHJlc01pbihIeilcIixcbiAgICAgICAgICBtYWtlKDgwMCwgNjAwMCwgNTAsIDE2MDAsICh2KSA9PlxuICAgICAgICAgICAgc2V0UHJlc2VuY2VSYW5nZT8uKHYsIHByZXNNYXgudmFsdWVBc051bWJlciksXG4gICAgICAgICAgKSxcbiAgICAgICAgKVxuICAgICAgICBjb25zdCBwcmVzTWF4ID0gbWFrZSgyMDAwLCA4MDAwLCA1MCwgNTIwMCwgKHYpID0+XG4gICAgICAgICAgc2V0UHJlc2VuY2VSYW5nZT8uKHByZXNNaW4udmFsdWVBc051bWJlciwgdiksXG4gICAgICAgICkgYXMgYW55XG4gICAgICAgIGNvbnN0IHByZXNNaW4gPSBwYW5lbC5xdWVyeVNlbGVjdG9yKFwiaW5wdXRbdHlwZT1yYW5nZV1cIikgYXMgYW55XG4gICAgICAgIGFkZChcInByZXNNYXgoSHopXCIsIHByZXNNYXgpXG4gICAgICAgIGNvbnN0IHN0YWIgPSBtYWtlKDQwLCA5NSwgMSwgNjAsICh2KSA9PlxuICAgICAgICAgIHNldFRyYWNrUGFyYW1zPy4oNiwgMTIsIDgsIHYgLyAxMDAsIDEyIC8gMTAwLCAyKSxcbiAgICAgICAgKVxuICAgICAgICBhZGQoXCJzdGFiKCUpXCIsIHN0YWIpXG4gICAgICAgIGNvbnN0IG1pbkFnZSA9IG1ha2UoMCwgNiwgMSwgMiwgKHYpID0+XG4gICAgICAgICAgc2V0VHJhY2tQYXJhbXM/Lig2LCAxMiwgOCwgc3RhYi52YWx1ZUFzTnVtYmVyIC8gMTAwLCAxMiAvIDEwMCwgdiksXG4gICAgICAgIClcbiAgICAgICAgYWRkKFwibWluQWdlKGZyKVwiLCBtaW5BZ2UpXG4gICAgICAgIGNvbnN0IGFscGhhID0gbWFrZSgzMCwgMTAwLCAxLCA1NSwgKHYpID0+IHNldE1hcENmZz8uKHYgLyAxMDAsIDIyMCkpXG4gICAgICAgIGFkZChcIm1hcEFscGhhXCIsIGFscGhhKVxuICAgICAgICBjb25zdCBzZXRMZWFkID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAgICAgLnNwZWN0cnVtX3NldF9sZWFkX3N0eWxlIGFzIEZ1bmN0aW9uXG4gICAgICAgIGNvbnN0IG9mZnNldCA9IG1ha2UoMCwgMjAsIDEsIDYsICh2KSA9PiBzZXRMZWFkPy4odikpXG4gICAgICAgIGFkZChcImxlYWRPZmZzZXRcIiwgb2Zmc2V0KVxuICAgICAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKHBhbmVsKVxuICAgICAgICBjb25zdCBnZXRUcmFja3MgPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgICAgICAuc3BlY3RydW1fdHJhY2tfY291bnQgYXMgRnVuY3Rpb25cbiAgICAgICAgY29uc3QgZGJnUHJlID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAgICAgLnNwZWN0cnVtX2RiZ19wcmUgYXMgRnVuY3Rpb25cbiAgICAgICAgY29uc3QgZGJnUG9zdCA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgICAgIC5zcGVjdHJ1bV9kYmdfcG9zdCBhcyBGdW5jdGlvblxuICAgICAgICBjb25zdCBkYmdNaW4gPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgICAgICAuc3BlY3RydW1fZGJnX2RibWluIGFzIEZ1bmN0aW9uXG4gICAgICAgIGNvbnN0IGRiZ01heCA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgICAgIC5zcGVjdHJ1bV9kYmdfZGJtYXggYXMgRnVuY3Rpb25cbiAgICAgICAgY29uc3QgdGljayA9ICgpID0+IHtcbiAgICAgICAgICB0cnkge1xuICAgICAgICAgICAgY29uc3QgbiA9IGdldFRyYWNrcz8uKCkgPz8gMFxuICAgICAgICAgICAgY29uc3QgbW9kZUxhYmVsMiA9XG4gICAgICAgICAgICAgIHRoaXMubW9kZSA9PT0gXCJiYXJzXCJcbiAgICAgICAgICAgICAgICA/IFwiYmFyc191OFwiXG4gICAgICAgICAgICAgICAgOiB0aGlzLm1vZGUgPT09IFwiYXJjX3NhZmVcIlxuICAgICAgICAgICAgICAgID8gXCJhcmNfdThcIlxuICAgICAgICAgICAgICAgIDogXCJhcmNfZjMyK3RyYWNrc1wiXG4gICAgICAgICAgICBjb25zdCBwcmUgPSBkYmdQcmU/LigpLnRvRml4ZWQoMylcbiAgICAgICAgICAgIGNvbnN0IHBvc3QgPSBkYmdQb3N0Py4oKS50b0ZpeGVkKDMpXG4gICAgICAgICAgICBjb25zdCBkbWluID0gZGJnTWluPy4oKS50b0ZpeGVkKDEpXG4gICAgICAgICAgICBjb25zdCBkbWF4ID0gZGJnTWF4Py4oKS50b0ZpeGVkKDEpXG4gICAgICAgICAgICBlbC50ZXh0Q29udGVudCA9IGB2aXo6ICR7bW9kZUxhYmVsMn0gfCB0cmFja3M9JHtufSB8IHByZT0ke3ByZX0gcG9zdD0ke3Bvc3R9IGRCPVske2RtaW59LCR7ZG1heH1dYFxuICAgICAgICAgIH0gY2F0Y2gge31cbiAgICAgICAgICBzZXRUaW1lb3V0KHRpY2ssIDEwMDApXG4gICAgICAgIH1cbiAgICAgICAgdGljaygpXG4gICAgICB9IGNhdGNoIChlcnIpIHtcbiAgICAgICAgY29uc29sZS53YXJuKFwiZGVidWcgSFVEIGluaXQgZmFpbGVkXCIsIGVycilcbiAgICAgIH1cbiAgICB9XG5cbiAgICAvLyBBbGxvY2F0ZSBhcnJheXMgZm9yIGZyZXF1ZW5jeSBkYXRhXG4gICAgdGhpcy5kYXRhQXJyYXkgPSBuZXcgVWludDhBcnJheShhbmFseXNlci5mcmVxdWVuY3lCaW5Db3VudClcbiAgICB0aGlzLmRhdGFGMzIgPSBuZXcgRmxvYXQzMkFycmF5KFxuICAgICAgbmV3IEFycmF5QnVmZmVyKGFuYWx5c2VyLmZyZXF1ZW5jeUJpbkNvdW50ICogNCksXG4gICAgKVxuXG4gICAgLy8gU3RvcmUgY2FudmFzIHJlZiBmb3IgbGF0ZXIgdXNlXG4gICAgcmV0dXJuIGNhbnZhc1JlZlxuICB9XG5cbiAgZHJhdyhhbmFseXNlcjogQW5hbHlzZXJOb2RlLCBjYW52YXNSZWY6IG51bWJlciA9IDApIHtcbiAgICBjb25zb2xlLmxvZyhcImRyYXdcIilcbiAgICBpZiAoIXRoaXMuaW5zdGFuY2UpIHJldHVyblxuXG4gICAgaWYgKHRoaXMubW9kZSA9PT0gXCJiYXJzXCIpIHtcbiAgICAgIGlmICghdGhpcy5kYXRhQXJyYXkpXG4gICAgICAgIHRoaXMuZGF0YUFycmF5ID0gbmV3IFVpbnQ4QXJyYXkoYW5hbHlzZXIuZnJlcXVlbmN5QmluQ291bnQpXG4gICAgICBhbmFseXNlci5nZXRCeXRlRnJlcXVlbmN5RGF0YSh0aGlzLmRhdGFBcnJheSlcbiAgICAgIGNvbnN0IG1lbW9yeSA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgICAubWVtb3J5IGFzIFdlYkFzc2VtYmx5Lk1lbW9yeVxuICAgICAgY29uc3QgZGF0YVB0ciA9IDEwMjQgPj4+IDBcbiAgICAgIG5ldyBVaW50OEFycmF5KG1lbW9yeS5idWZmZXIsIGRhdGFQdHIsIHRoaXMuZGF0YUFycmF5Lmxlbmd0aCkuc2V0KFxuICAgICAgICB0aGlzLmRhdGFBcnJheSxcbiAgICAgIClcbiAgICAgIGNvbnN0IGRyYXdCYXJzID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAgIC5zcGVjdHJ1bV9kcmF3X2JhcnMgYXMgRnVuY3Rpb25cbiAgICAgIGRyYXdCYXJzKGNhbnZhc1JlZiwgZGF0YVB0ciwgdGhpcy5kYXRhQXJyYXkubGVuZ3RoKVxuICAgICAgcmV0dXJuXG4gICAgfVxuXG4gICAgaWYgKHRoaXMubW9kZSA9PT0gXCJhcmNfc2FmZVwiKSB7XG4gICAgICBpZiAoIXRoaXMuZGF0YUYzMilcbiAgICAgICAgdGhpcy5kYXRhRjMyID0gbmV3IEZsb2F0MzJBcnJheShcbiAgICAgICAgICBuZXcgQXJyYXlCdWZmZXIoYW5hbHlzZXIuZnJlcXVlbmN5QmluQ291bnQgKiA0KSxcbiAgICAgICAgKVxuICAgICAgYW5hbHlzZXIuZ2V0RmxvYXRGcmVxdWVuY3lEYXRhKHRoaXMuZGF0YUYzMilcbiAgICAgIGNvbnN0IG1lbW9yeSA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgICAubWVtb3J5IGFzIFdlYkFzc2VtYmx5Lk1lbW9yeVxuICAgICAgY29uc3QgZ2V0UHRyID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAgIC5zcGVjdHJ1bV9pbnB1dF9wdHJfZjMyIGFzIEZ1bmN0aW9uXG4gICAgICBjb25zdCBkYXRhUHRyID0gZ2V0UHRyPy4oKSA/PyAxMDI0XG4gICAgICBuZXcgRmxvYXQzMkFycmF5KG1lbW9yeS5idWZmZXIsIGRhdGFQdHIsIHRoaXMuZGF0YUYzMi5sZW5ndGgpLnNldChcbiAgICAgICAgdGhpcy5kYXRhRjMyIGFzIHVua25vd24gYXMgQXJyYXlMaWtlPG51bWJlcj4sXG4gICAgICApXG4gICAgICBjb25zdCBkcmF3QXJjU2ltcGxlID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAgIC5zcGVjdHJ1bV9kcmF3X2FyY19zaW1wbGVfZjMyIGFzIEZ1bmN0aW9uXG4gICAgICBkcmF3QXJjU2ltcGxlKGNhbnZhc1JlZiwgZGF0YVB0ciwgdGhpcy5kYXRhRjMyLmxlbmd0aClcbiAgICAgIHJldHVyblxuICAgIH1cblxuICAgIGlmICghdGhpcy5kYXRhRjMyKSByZXR1cm5cblxuICAgIGFuYWx5c2VyLmdldEZsb2F0RnJlcXVlbmN5RGF0YSh0aGlzLmRhdGFGMzIpXG5cbiAgICAvLyBHZXQgV0FTTSBtZW1vcnlcbiAgICBjb25zdCBtZW1vcnkgPSB0aGlzLmluc3RhbmNlLmV4cG9ydHMubWVtb3J5IGFzIFdlYkFzc2VtYmx5Lk1lbW9yeVxuXG4gICAgLy8gQWxsb2NhdGUgc3BhY2UgaW4gV0FTTSBtZW1vcnkgZm9yIHRoZSBkYXRhXG4gICAgLy8gU2ltcGxlIGFsbG9jYXRpb24gcmVnaW9uXG4gICAgbGV0IGRhdGFQdHIgPSAxMDI0IC8vIDQtYnl0ZSBhbGlnbmVkXG5cbiAgICAvLyBDb3B5IHJhdyBkYXRhIHRvIFdBU00gbWVtb3J5IChaaWcgZG9lcyBwcmVwcm9jZXNzaW5nKVxuICAgIGNvbnN0IGdldFB0ckYgPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgIC5zcGVjdHJ1bV9pbnB1dF9wdHJfZjMyIGFzIEZ1bmN0aW9uXG4gICAgY29uc3QgcHRyRiA9IGdldFB0ckY/LigpID8/IGRhdGFQdHJcbiAgICBuZXcgRmxvYXQzMkFycmF5KG1lbW9yeS5idWZmZXIsIHB0ckYsIHRoaXMuZGF0YUYzMi5sZW5ndGgpLnNldChcbiAgICAgIHRoaXMuZGF0YUYzMiBhcyB1bmtub3duIGFzIEFycmF5TGlrZTxudW1iZXI+LFxuICAgIClcblxuICAgIC8vIFVzZSBhcmMgcmVuZGVyZXJcbiAgICBjb25zdCBkcmF3QXJjRjMyID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAuc3BlY3RydW1fZHJhd19hcmNfZjMyIGFzIEZ1bmN0aW9uXG4gICAgZHJhd0FyY0YzMihjYW52YXNSZWYsIHB0ckYsIHRoaXMuZGF0YUYzMi5sZW5ndGgpXG5cbiAgICAvLyBPcHRpb25hbCBjYXB0dXJlIGZvciBvZmZsaW5lIGFuYWx5c2lzXG4gICAgaWYgKG5ldyBVUkwobG9jYXRpb24uaHJlZikuc2VhcmNoUGFyYW1zLmdldChcImNhcHR1cmVcIikgPT09IFwiMVwiKSB7XG4gICAgICB0cnkge1xuICAgICAgICBjb25zdCBkdW1wID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAgICAgLnNwZWN0cnVtX2R1bXBfcG9zdF9iaW5zIGFzIEZ1bmN0aW9uXG4gICAgICAgIGNvbnN0IHBvc3RMZW4gPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgICAgICAuc3BlY3RydW1fcG9zdF9sZW4gYXMgRnVuY3Rpb25cbiAgICAgICAgY29uc3Qgb3V0UHRyID0gZ2V0UHRyRj8uKCkgPz8gcHRyRlxuICAgICAgICBjb25zdCBjb3VudCA9IGR1bXAob3V0UHRyLCAyMDQ4KSBhcyBudW1iZXJcbiAgICAgICAgY29uc3QgYmlucyA9IEFycmF5LmZyb20oXG4gICAgICAgICAgbmV3IEZsb2F0MzJBcnJheShtZW1vcnkuYnVmZmVyLCBvdXRQdHIsIE1hdGgubWluKGNvdW50LCAyNTYpKSxcbiAgICAgICAgKVxuICAgICAgICBjb25zdCBkYmdQcmUgPSAodGhpcy5pbnN0YW5jZS5leHBvcnRzIGFzIGFueSlcbiAgICAgICAgICAuc3BlY3RydW1fZGJnX3ByZSBhcyBGdW5jdGlvblxuICAgICAgICBjb25zdCBkYmdQb3N0ID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAgICAgLnNwZWN0cnVtX2RiZ19wb3N0IGFzIEZ1bmN0aW9uXG4gICAgICAgIGNvbnN0IGRiZ01pbiA9ICh0aGlzLmluc3RhbmNlLmV4cG9ydHMgYXMgYW55KVxuICAgICAgICAgIC5zcGVjdHJ1bV9kYmdfZGJtaW4gYXMgRnVuY3Rpb25cbiAgICAgICAgY29uc3QgZGJnTWF4ID0gKHRoaXMuaW5zdGFuY2UuZXhwb3J0cyBhcyBhbnkpXG4gICAgICAgICAgLnNwZWN0cnVtX2RiZ19kYm1heCBhcyBGdW5jdGlvblxuICAgICAgICBjb25zdCBwYXlsb2FkID0gSlNPTi5zdHJpbmdpZnkoe1xuICAgICAgICAgIHQ6IHBlcmZvcm1hbmNlLm5vdygpIC8gMTAwMCxcbiAgICAgICAgICBwcmU6IGRiZ1ByZT8uKCksXG4gICAgICAgICAgcG9zdDogZGJnUG9zdD8uKCksXG4gICAgICAgICAgZGI6IFtkYmdNaW4/LigpLCBkYmdNYXg/LigpXSxcbiAgICAgICAgICBtb2RlOiB0aGlzLm1vZGUsXG4gICAgICAgICAgYmlucyxcbiAgICAgICAgfSlcbiAgICAgICAgZmV0Y2goXCIvY2FwdHVyZVwiLCB7IG1ldGhvZDogXCJQT1NUXCIsIGJvZHk6IHBheWxvYWQgfSlcbiAgICAgIH0gY2F0Y2gge31cbiAgICB9XG4gIH1cblxuICByZXNpemUod2lkdGg6IG51bWJlciwgaGVpZ2h0OiBudW1iZXIpIHtcbiAgICBpZiAoIXRoaXMuaW5zdGFuY2UpIHJldHVyblxuXG4gICAgY29uc3Qgc2V0U2l6ZSA9IHRoaXMuaW5zdGFuY2UuZXhwb3J0cy5zcGVjdHJ1bV9zZXRfY2FudmFzX3NpemUgYXMgRnVuY3Rpb25cbiAgICBzZXRTaXplKHdpZHRoLCBoZWlnaHQpXG4gIH1cblxuICAvLyBBZGQgYSBuZXcgY2FudmFzIGFuZCByZXR1cm4gaXRzIHJlZmVyZW5jZVxuICBhZGRDYW52YXMoY2FudmFzOiBIVE1MQ2FudmFzRWxlbWVudCk6IG51bWJlciB7XG4gICAgY29uc3QgY3R4ID0gY2FudmFzLmdldENvbnRleHQoXCIyZFwiKSFcbiAgICBjb25zdCByZWYgPSB0aGlzLmNhbnZhc2VzLmxlbmd0aFxuICAgIHRoaXMuY2FudmFzZXMucHVzaChjdHgpXG4gICAgdGhpcy5ncmFkaWVudHMucHVzaChudWxsKVxuXG4gICAgLy8gQWxzbyBhZGQgdG8gZGF0YSBwcm9jZXNzb3IgaWYgaXQgZXhpc3RzXG4gICAgaWYgKHRoaXMuZGF0YVByb2Nlc3Nvcikge1xuICAgICAgdGhpcy5kYXRhUHJvY2Vzc29yLnByb2Nlc3Nvci5hZGRDYW52YXMoY3R4KVxuICAgIH1cblxuICAgIHJldHVybiByZWZcbiAgfVxuXG4gIC8vIFJlbW92ZSBhIGNhbnZhcyBieSByZWZlcmVuY2VcbiAgcmVtb3ZlQ2FudmFzKHJlZjogbnVtYmVyKSB7XG4gICAgaWYgKHJlZiA+PSAwICYmIHJlZiA8IHRoaXMuY2FudmFzZXMubGVuZ3RoKSB7XG4gICAgICB0aGlzLmNhbnZhc2VzW3JlZl0gPSBudWxsXG4gICAgICB0aGlzLmdyYWRpZW50c1tyZWZdID0gbnVsbFxuXG4gICAgICAvLyBBbHNvIHJlbW92ZSBmcm9tIGRhdGEgcHJvY2Vzc29yIGlmIGl0IGV4aXN0c1xuICAgICAgaWYgKHRoaXMuZGF0YVByb2Nlc3Nvcikge1xuICAgICAgICB0aGlzLmRhdGFQcm9jZXNzb3IucHJvY2Vzc29yLnJlbW92ZUNhbnZhcyhyZWYpXG4gICAgICB9XG4gICAgfVxuICB9XG5cbiAgLy8gR2V0IGJ1ZmZlciBzdGF0aXN0aWNzIGZvciBkZWJ1Z2dpbmdcbiAgZ2V0QnVmZmVyU3RhdHMoKSB7XG4gICAgaWYgKCF0aGlzLmluc3RhbmNlKSByZXR1cm4gbnVsbFxuXG4gICAgY29uc3QgYnVmZmVyU2l6ZUZuID0gdGhpcy5pbnN0YW5jZS5leHBvcnRzXG4gICAgICAuY2FudmFzX2NtZF9idWZmZXJfc2l6ZSBhcyBGdW5jdGlvblxuICAgIGlmIChidWZmZXJTaXplRm4pIHtcbiAgICAgIHJldHVybiB7XG4gICAgICAgIGNvbW1hbmRDb3VudDogYnVmZmVyU2l6ZUZuKCksXG4gICAgICB9XG4gICAgfVxuICAgIHJldHVybiBudWxsXG4gIH1cblxuICAvLyBDbGVhbnVwIG1ldGhvZFxuICBjbGVhbnVwKCkge1xuICAgIC8vIE5vIG5lZWQgdG8gcmV2b2tlIFVSTHMgd2l0aCBzZXJ2aWNlIHdvcmtlciBhcHByb2FjaFxuICAgIHRoaXMuaW5zdGFuY2UgPSBudWxsXG4gICAgdGhpcy5jYW52YXNlcyA9IFtdXG4gICAgdGhpcy5ncmFkaWVudHMgPSBbXVxuICAgIHRoaXMuZGF0YUFycmF5ID0gbnVsbFxuICAgIHRoaXMuZGF0YVByb2Nlc3NvciA9IG51bGxcbiAgICB0aGlzLndhc2kgPSBudWxsXG4gIH1cbn1cblxuLy8gU2luZ2xldG9uIGZvciBlYXN5IHVzYWdlIC0gYnV0IG5vdyB0cmFja3MgY2FudmFzIHJlZnNcbmxldCBpbnN0YW5jZTogU3BlY3RydW1XYXNtIHwgbnVsbCA9IG51bGxcbmxldCBkZWZhdWx0Q2FudmFzUmVmOiBudW1iZXIgPSAwXG5cbmV4cG9ydCBhc3luYyBmdW5jdGlvbiBnZXRTcGVjdHJ1bVdhc20oKTogUHJvbWlzZTx7XG4gIHdhc206IFNwZWN0cnVtV2FzbVxuICBjYW52YXNSZWY6IG51bWJlclxufT4ge1xuICBpZiAoIWluc3RhbmNlKSB7XG4gICAgaW5zdGFuY2UgPSBuZXcgU3BlY3RydW1XYXNtKClcbiAgfVxuICByZXR1cm4geyB3YXNtOiBpbnN0YW5jZSwgY2FudmFzUmVmOiBkZWZhdWx0Q2FudmFzUmVmIH1cbn1cblxuLy8gSW5pdGlhbGl6ZSB3aXRoIGEgY2FudmFzIGFuZCByZXR1cm4gYm90aCB0aGUgaW5zdGFuY2UgYW5kIGNhbnZhcyByZWZcbmV4cG9ydCBhc3luYyBmdW5jdGlvbiBpbml0U3BlY3RydW1XYXNtKFxuICBjYW52YXM6IEhUTUxDYW52YXNFbGVtZW50LFxuICBhbmFseXNlcjogQW5hbHlzZXJOb2RlLFxuKTogUHJvbWlzZTx7IHdhc206IFNwZWN0cnVtV2FzbTsgY2FudmFzUmVmOiBudW1iZXIgfT4ge1xuICBpZiAoIWluc3RhbmNlKSB7XG4gICAgaW5zdGFuY2UgPSBuZXcgU3BlY3RydW1XYXNtKClcbiAgfVxuICBjb25zdCBjYW52YXNSZWYgPSBhd2FpdCBpbnN0YW5jZS5pbml0aWFsaXplKGNhbnZhcywgYW5hbHlzZXIpXG4gIGlmIChkZWZhdWx0Q2FudmFzUmVmID09PSAwKSB7XG4gICAgZGVmYXVsdENhbnZhc1JlZiA9IGNhbnZhc1JlZlxuICB9XG4gIHJldHVybiB7IHdhc206IGluc3RhbmNlLCBjYW52YXNSZWYgfVxufVxuIiwKICAgICJpbXBvcnQgdHJhbnNjcmlwdGlvblRleHQgZnJvbSBcIi4uL3RyYW5zY3JpcHRpb24tc2ltcGxlLnR4dFwiXG5pbXBvcnQgYXVkaW9GaWxlIGZyb20gXCIuLi9ub3QtbXktZmF1bHQubXAzXCJcbmltcG9ydCB7IGluaXRTcGVjdHJ1bVdhc20gfSBmcm9tIFwiLi9zcGVjdHJ1bVwiXG5cbmZ1bmN0aW9uIHdhaXRGb3JDb250ZW50TG9hZCgpOiBQcm9taXNlPHZvaWQ+IHtcbiAgcmV0dXJuIG5ldyBQcm9taXNlKChyZXNvbHZlKSA9PiB7XG4gICAgaWYgKGRvY3VtZW50LnJlYWR5U3RhdGUgPT09IFwiY29tcGxldGVcIikge1xuICAgICAgcmVzb2x2ZSgpXG4gICAgfSBlbHNlIHtcbiAgICAgIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKFwiRE9NQ29udGVudExvYWRlZFwiLCAoKSA9PiByZXNvbHZlKCkpXG4gICAgfVxuICB9KVxufVxuXG5hd2FpdCB3YWl0Rm9yQ29udGVudExvYWQoKVxuXG5mdW5jdGlvbiB3aWRnZXQ8SyBleHRlbmRzIGtleW9mIEhUTUxFbGVtZW50VGFnTmFtZU1hcD4oXG4gIHRhZzogSyxcbiAgd2l0aGluOiBIVE1MRWxlbWVudCB8IERvY3VtZW50ID0gZG9jdW1lbnQsXG4pOiBIVE1MRWxlbWVudFRhZ05hbWVNYXBbS10ge1xuICByZXR1cm4gd2l0aGluLmdldEVsZW1lbnRzQnlUYWdOYW1lKHRhZylbMF1cbn1cblxuY29uc3QgYXVkaW8gPSB3aWRnZXQoXCJhdWRpb1wiKVxuY29uc3QgY2FudmFzID0gd2lkZ2V0KFwiY2FudmFzXCIpXG5cbmNvbnN0IHZpc3VhbGl6ZXIgPSB3aWRnZXQoXCJmaWd1cmVcIilcbmNvbnN0IHJlY29yZEJ1dHRvbiA9IHdpZGdldChcImJ1dHRvblwiLCB3aWRnZXQoXCJtZW51XCIpKVxuXG52aXN1YWxpemVyLmFkZEV2ZW50TGlzdGVuZXIoXCJjbGlja1wiLCAoKSA9PiB7XG4gIGlmIChhdWRpby5wYXVzZWQpIHtcbiAgICBhdWRpby5wbGF5KClcbiAgfSBlbHNlIHtcbiAgICBhdWRpby5wYXVzZSgpXG4gIH1cbn0pXG5cbmNvbnN0IGF1ZGlvUmVzcG9uc2UgPSBhd2FpdCBmZXRjaChhdWRpb0ZpbGUsIHsgbW9kZTogXCJjb3JzXCIgfSlcbmNvbnN0IGF1ZGlvQmxvYiA9IGF3YWl0IGF1ZGlvUmVzcG9uc2UuYmxvYigpXG5jb25zdCBhdWRpb1VybCA9IFVSTC5jcmVhdGVPYmplY3RVUkwoYXVkaW9CbG9iKVxuXG5hdWRpby5zcmMgPSBhdWRpb1VybFxuXG5jb25zdCBhdWRpb0NvbnRleHQgPSBuZXcgd2luZG93LkF1ZGlvQ29udGV4dCgpXG5jb25zdCBhbmFseXNlciA9IGF1ZGlvQ29udGV4dC5jcmVhdGVBbmFseXNlcigpXG5hbmFseXNlci5mZnRTaXplID0gNDA5NlxuXG5jb25zdCBzb3VyY2UgPSBhdWRpb0NvbnRleHQuY3JlYXRlTWVkaWFFbGVtZW50U291cmNlKGF1ZGlvKVxuc291cmNlLmNvbm5lY3QoYW5hbHlzZXIpXG5hbmFseXNlci5jb25uZWN0KGF1ZGlvQ29udGV4dC5kZXN0aW5hdGlvbilcblxuLy8gRW5zdXJlIGNhbnZhcyBoYXMgY29ycmVjdCBkZXZpY2UtcGl4ZWwgc2l6ZSBiZWZvcmUgaW5pdGlhbGl6aW5nIFdBU01cbmZ1bmN0aW9uIGVuc3VyZUluaXRpYWxDYW52YXNTaXplKCkge1xuICBjb25zdCBkcHIgPSBNYXRoLm1heCgxLCB3aW5kb3cuZGV2aWNlUGl4ZWxSYXRpbyB8fCAxKVxuICBjb25zdCB3ID0gTWF0aC5mbG9vcihjYW52YXMuY2xpZW50V2lkdGggKiBkcHIpIHx8IGNhbnZhcy53aWR0aFxuICBjb25zdCBoID0gTWF0aC5mbG9vcihjYW52YXMuY2xpZW50SGVpZ2h0ICogZHByKSB8fCBjYW52YXMuaGVpZ2h0XG4gIGNhbnZhcy53aWR0aCA9IHdcbiAgY2FudmFzLmhlaWdodCA9IGhcbn1cbmVuc3VyZUluaXRpYWxDYW52YXNTaXplKClcblxuLy8gQ3JlYXRlIHRoZSBhcmMtYmFzZWQgc3BlY3RydW0gdmlzdWFsaXplclxuY29uc3QgeyB3YXNtOiBzcGVjdHJ1bVZpc3VhbGl6ZXIsIGNhbnZhc1JlZiB9ID0gYXdhaXQgaW5pdFNwZWN0cnVtV2FzbShcbiAgY2FudmFzLFxuICBhbmFseXNlcixcbilcbi8vIFJlLXN5bmMgc2l6ZSBhZnRlciBpbml0IGluIGNhc2UgRFBSL2xheW91dCBjaGFuZ2VkXG5zcGVjdHJ1bVZpc3VhbGl6ZXIucmVzaXplKGNhbnZhcy53aWR0aCwgY2FudmFzLmhlaWdodClcblxuLy8gQW5pbWF0aW9uIGxvb3AgZm9yIHNwZWN0cnVtIChwZXJwZXR1YWwgckFGOyBjaGVja3MgYXVkaW8gc3RhdGUgZWFjaCB0aWNrKVxuYXVkaW8ub25wbGF5aW5nID0gYXN5bmMgKCkgPT4ge1xuICB0cnkge1xuICAgIGF3YWl0IGF1ZGlvQ29udGV4dC5yZXN1bWUoKVxuICB9IGNhdGNoIHt9XG59XG5cbmF1ZGlvLm9uc2Vla2VkID0gKCkgPT4ge1xuICBhbmltYXRlTHlyaWNzKGF1ZGlvLmN1cnJlbnRUaW1lKVxufVxuXG5hdWRpby5vbmVycm9yID0gKCkgPT4ge1xuICBhbGVydChcIkVycm9yIGxvYWRpbmcgYXVkaW9cIilcbn1cblxuLy8gUGFyc2UgdGhlIHNpbXBsZSB0cmFuc2NyaXB0aW9uIGZvcm1hdFxuY29uc3QgbGluZXMgPSB0cmFuc2NyaXB0aW9uVGV4dC50cmltKCkuc3BsaXQoXCJcXG5cIilcbmxldCB3czogc3RyaW5nW10gPSBbXVxubGV0IHQwOiBudW1iZXJbXSA9IFtdXG5sZXQgdDE6IG51bWJlcltdID0gW11cblxuZm9yIChjb25zdCBsaW5lIG9mIGxpbmVzKSB7XG4gIGNvbnN0IFt0aW1lLCAuLi53b3JkUGFydHNdID0gbGluZS5zcGxpdChcIiBcIilcbiAgY29uc3Qgd29yZCA9IHdvcmRQYXJ0cy5qb2luKFwiIFwiKVxuICB3cy5wdXNoKHdvcmQpXG4gIHQwLnB1c2gocGFyc2VGbG9hdCh0aW1lKSlcbiAgdDEucHVzaChwYXJzZUZsb2F0KHRpbWUpICsgMSlcbn1cblxubGV0IG4gPSB3cy5sZW5ndGhcblxudDAucHVzaCh0MVtuIC0gMV0pXG50MS5wdXNoKEluZmluaXR5KVxuXG5mb3IgKGxldCBpID0gMDsgaSA8IG47IGkrKykge1xuICB0MVtpXSA9IHQwW2kgKyAxXVxufVxuXG4vLyBJbnNlcnQgcGF1c2UgbWFya2VycyBmb3IgZ2Fwc1xuZm9yIChsZXQgaSA9IDE7IGkgPCB3cy5sZW5ndGggLSAxOyBpKyspIHtcbiAgY29uc3Qgc2luY2VQcmV2aW91c1N0YXJ0ID0gdDBbaV0gLSB0MFtpIC0gMV1cbiAgaWYgKHNpbmNlUHJldmlvdXNTdGFydCA+IDIpIHtcbiAgICB3cy5zcGxpY2UoaSwgMCwgXCJcXG5cIilcbiAgICB0MC5zcGxpY2UoaSwgMCwgdDBbaV0gKyAwLjEpXG4gICAgdDEuc3BsaWNlKGksIDAsIHQxW2ldICsgMC4xKVxuICB9XG59XG5cbmNvbnN0IHdvcmR0YWdzOiBIVE1MRWxlbWVudFtdID0gW11cbmNvbnN0IGx5cmljcyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoXCJmaWdjYXB0aW9uXCIpXG5mb3IgKGNvbnN0IFtpLCB3b3JkXSBvZiB3cy5lbnRyaWVzKCkpIHtcbiAgaWYgKHdvcmQgPT0gXCJcXG5cIikge1xuICAgIGNvbnN0IHRhZyA9IGxpbmVicmVhaygpXG4gICAgd29yZHRhZ3MucHVzaCh0YWcpXG4gICAgbHlyaWNzLmFwcGVuZENoaWxkKHRhZylcbiAgfSBlbHNlIHtcbiAgICBjb25zdCB0YWcgPSB3b3Jkc3Bhbih3b3JkKVxuICAgIHdvcmR0YWdzLnB1c2gobHlyaWNzLmFwcGVuZENoaWxkKHRhZykpXG5cbiAgICBpZiAod29yZC5lbmRzV2l0aChcIixcIikpIHtcbiAgICAgIHRhZy5pbnNlcnRBZGphY2VudEVsZW1lbnQoXCJhZnRlcmVuZFwiLCBsaW5lYnJlYWsoKSlcbiAgICB9XG4gIH1cbn1cblxud2lkZ2V0KFwiZmlnY2FwdGlvblwiKS5yZXBsYWNlV2l0aChseXJpY3MpXG5cbmFuaW1hdGVMeXJpY3MoLUluZmluaXR5KVxuXG5mdW5jdGlvbiB3b3Jkc3Bhbih3b3JkOiBzdHJpbmcpIHtcbiAgY29uc3QgdGFnID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcInNwYW5cIilcbiAgdGFnLnRleHRDb250ZW50ID0gd29yZFxuICByZXR1cm4gdGFnXG59XG5cbmZ1bmN0aW9uIGxpbmVicmVhaygpIHtcbiAgY29uc3QgdGFnID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcImRpdlwiKVxuICB0YWcuc3R5bGUuZmxleEJhc2lzID0gXCIxMDAlXCJcbiAgdGFnLnN0eWxlLmhlaWdodCA9IFwiMFwiXG4gIHJldHVybiB0YWdcbn1cblxuZnVuY3Rpb24gbmV4dEFuaW1hdGlvbkZyYW1lKCk6IFByb21pc2U8dm9pZD4ge1xuICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUpID0+IHtcbiAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoKCkgPT4ge1xuICAgICAgcmVzb2x2ZSgpXG4gICAgfSlcbiAgfSlcbn1cblxuZnVuY3Rpb24gbmV4dEV2ZW50RnJvbTxLIGV4dGVuZHMga2V5b2YgSFRNTEVsZW1lbnRFdmVudE1hcD4oXG4gIGVsZW1lbnQ6IEhUTUxFbGVtZW50LFxuICBldmVudE5hbWU6IEssXG4pOiBQcm9taXNlPEhUTUxFbGVtZW50RXZlbnRNYXBbS10+IHtcbiAgcmV0dXJuIG5ldyBQcm9taXNlKChyZXNvbHZlKSA9PiB7XG4gICAgZWxlbWVudC5hZGRFdmVudExpc3RlbmVyKGV2ZW50TmFtZSwgKGV2ZW50KSA9PiByZXNvbHZlKGV2ZW50KSwge1xuICAgICAgb25jZTogdHJ1ZSxcbiAgICB9KVxuICB9KVxufVxuXG4vLyBSZXZlcnQgdG8gZXZlbnQtZ2F0ZWQgYW5pbWF0aW9uIGxvb3AgZm9yIHJlbGlhYmlsaXR5IHdpdGggbWVkaWEgZXZlbnRzXG5hc3luYyBmdW5jdGlvbiBhbmltYXRlKCk6IFByb21pc2U8dm9pZD4ge1xuICB3aGlsZSAodHJ1ZSkge1xuICAgIGNvbnNvbGUubG9nKFwiYW5pbWF0ZVwiKVxuICAgIGF3YWl0IG5leHRFdmVudEZyb20oYXVkaW8sIFwicGxheWluZ1wiKVxuICAgIGF3YWl0IGF1ZGlvQ29udGV4dC5yZXN1bWUoKVxuICAgIGNvbnNvbGUubG9nKFwicmVzdW1lXCIpXG4gICAgd2hpbGUgKCFhdWRpby5wYXVzZWQgJiYgIWF1ZGlvLmVuZGVkKSB7XG4gICAgICBhd2FpdCBuZXh0QW5pbWF0aW9uRnJhbWUoKVxuICAgICAgY29uc29sZS5sb2coXCJmcmFtZVwiKVxuICAgICAgc3BlY3RydW1WaXN1YWxpemVyLmRyYXcoYW5hbHlzZXIsIGNhbnZhc1JlZilcbiAgICAgIGFuaW1hdGVMeXJpY3MoYXVkaW8uY3VycmVudFRpbWUpXG4gICAgfVxuICB9XG59XG5hbmltYXRlKClcblxuZnVuY3Rpb24gYW5pbWF0ZUx5cmljcyh0OiBudW1iZXIpOiB2b2lkIHtcbiAgbGV0IGkgPSAwXG4gIHdoaWxlIChpIDwgd3MubGVuZ3RoKSB7XG4gICAgY29uc3Qgc3RhcnQgPSB0MFtpXSxcbiAgICAgIGVuZCA9IHN0YXJ0ICsgMSxcbiAgICAgIGR1cmF0aW9uID0gZW5kIC0gc3RhcnQsXG4gICAgICBjZW50ZXIgPSBzdGFydCArIGR1cmF0aW9uIC8gMlxuXG4gICAgY29uc3QgZGlzdGFuY2UgPSBzdGFydCAtIHQsXG4gICAgICBpbnRlbnNpdHkgPSBNYXRoLmV4cCgtZGlzdGFuY2UgKiBkaXN0YW5jZSAqIDIpLFxuICAgICAgcGFzdEZhZGUgPSB0ID4gZW5kID8gTWF0aC5leHAoLSh0IC0gZW5kKSAqIDAuNSkgOiAxLFxuICAgICAgZmluYWwgPSBpbnRlbnNpdHkgKiBwYXN0RmFkZVxuXG4gICAgd29yZHRhZ3NbaV0uc3R5bGUub3BhY2l0eSA9IFN0cmluZyhmaW5hbCAqIDAuNylcblxuICAgIGlmIChkaXN0YW5jZSA8PSAwKSB7XG4gICAgICB3b3JkdGFnc1tpXS5zY3JvbGxJbnRvVmlldyh7IGJlaGF2aW9yOiBcInNtb290aFwiLCBibG9jazogXCJjZW50ZXJcIiB9KVxuICAgIH1cblxuICAgIGkrK1xuICB9XG59XG5cbi8vIEhhbmRsZSBjYW52YXMgcmVzaXplICsgaW5pdGlhbCBzaXplXG5mdW5jdGlvbiByZXNpemVDYW52YXMoKSB7XG4gIGNvbnN0IGRwciA9IE1hdGgubWF4KDEsIHdpbmRvdy5kZXZpY2VQaXhlbFJhdGlvIHx8IDEpXG4gIGNvbnN0IHcgPSBNYXRoLmZsb29yKGNhbnZhcy5jbGllbnRXaWR0aCAqIGRwcilcbiAgY29uc3QgaCA9IE1hdGguZmxvb3IoY2FudmFzLmNsaWVudEhlaWdodCAqIGRwcilcbiAgaWYgKGNhbnZhcy53aWR0aCAhPT0gdyB8fCBjYW52YXMuaGVpZ2h0ICE9PSBoKSB7XG4gICAgY2FudmFzLndpZHRoID0gd1xuICAgIGNhbnZhcy5oZWlnaHQgPSBoXG4gICAgc3BlY3RydW1WaXN1YWxpemVyLnJlc2l6ZSh3LCBoKVxuICB9XG59XG5yZXNpemVDYW52YXMoKVxud2luZG93LmFkZEV2ZW50TGlzdGVuZXIoXCJyZXNpemVcIiwgcmVzaXplQ2FudmFzKVxuXG5jb25zdCBjdHggPSBjYW52YXMuZ2V0Q29udGV4dChcIjJkXCIpIVxuXG5yZWNvcmRCdXR0b24ub25jbGljayA9IGFzeW5jICgpID0+IHtcbiAgdHJ5IHtcbiAgICBhdWRpby5jdXJyZW50VGltZSA9IDBcblxuICAgIGNvbnN0IHN0cmVhbSA9IGF3YWl0IG5hdmlnYXRvci5tZWRpYURldmljZXMuZ2V0RGlzcGxheU1lZGlhKHtcbiAgICAgIHZpZGVvOiB7IGRpc3BsYXlTdXJmYWNlOiBcImJyb3dzZXJcIiB9IGFzIGFueSxcbiAgICAgIGF1ZGlvOiB0cnVlLFxuICAgICAgcHJlZmVyQ3VycmVudFRhYjogdHJ1ZSxcbiAgICB9IGFzIERpc3BsYXlNZWRpYVN0cmVhbU9wdGlvbnMpXG5cbiAgICBjb25zdCB2aWRlb1RyYWNrID0gc3RyZWFtLmdldFZpZGVvVHJhY2tzKClbMF1cbiAgICBpZiAodmlkZW9UcmFjay5jcm9wVG8pIHtcbiAgICAgIGNvbnN0IGNyb3BUYXJnZXQgPSBhd2FpdCBDcm9wVGFyZ2V0LmZyb21FbGVtZW50KHZpc3VhbGl6ZXIpXG4gICAgICBhd2FpdCB2aWRlb1RyYWNrLmNyb3BUbyhjcm9wVGFyZ2V0KVxuICAgIH1cblxuICAgIGNvbnN0IG1lZGlhUmVjb3JkZXIgPSBuZXcgTWVkaWFSZWNvcmRlcihzdHJlYW0sIHtcbiAgICAgIG1pbWVUeXBlOiBcInZpZGVvL3dlYm1cIixcbiAgICB9KVxuXG4gICAgY29uc3QgcmVjb3JkZWRDaHVua3M6IEJsb2JbXSA9IFtdXG5cbiAgICBtZWRpYVJlY29yZGVyLm9uZGF0YWF2YWlsYWJsZSA9IChldmVudCkgPT4ge1xuICAgICAgaWYgKGV2ZW50LmRhdGEuc2l6ZSA+IDApIHtcbiAgICAgICAgcmVjb3JkZWRDaHVua3MucHVzaChldmVudC5kYXRhKVxuICAgICAgfVxuICAgIH1cblxuICAgIG1lZGlhUmVjb3JkZXIub25zdG9wID0gKCkgPT4ge1xuICAgICAgY29uc3QgYmxvYiA9IG5ldyBCbG9iKHJlY29yZGVkQ2h1bmtzLCB7IHR5cGU6IFwidmlkZW8vd2VibVwiIH0pXG4gICAgICBjb25zdCB1cmwgPSBVUkwuY3JlYXRlT2JqZWN0VVJMKGJsb2IpXG4gICAgICBjb25zdCBhID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudChcImFcIilcbiAgICAgIGEuaHJlZiA9IHVybFxuICAgICAgYS5kb3dubG9hZCA9IFwibHlyaWNzLXZpZGVvLndlYm1cIlxuICAgICAgYS5jbGljaygpXG4gICAgICBzdHJlYW0uZ2V0VHJhY2tzKCkuZm9yRWFjaCgodHJhY2spID0+IHRyYWNrLnN0b3AoKSlcbiAgICB9XG5cbiAgICBtZWRpYVJlY29yZGVyLnN0YXJ0KClcblxuICAgIHVwZGF0ZVN0YXR1cyhcIlJlY29yZGluZyBmdWxsIHNvbmcuLi5cIilcbiAgICB2aXN1YWxpemVyLmNsYXNzTGlzdC5hZGQoXCJyZWNvcmRpbmdcIilcblxuICAgIGlmIChhdWRpb0NvbnRleHQuc3RhdGUgPT09IFwic3VzcGVuZGVkXCIpIHtcbiAgICAgIGF1ZGlvQ29udGV4dC5yZXN1bWUoKVxuICAgIH1cblxuICAgIGF1ZGlvLmFkZEV2ZW50TGlzdGVuZXIoXCJlbmRlZFwiLCAoKSA9PiB7XG4gICAgICBtZWRpYVJlY29yZGVyLnN0b3AoKVxuICAgIH0pXG5cbiAgICBhdWRpby5wbGF5KClcbiAgfSBjYXRjaCAoZXJyKSB7XG4gICAgdXBkYXRlU3RhdHVzKFwiRXJyb3I6IFwiICsgKGVyciBhcyBFcnJvcikubWVzc2FnZSlcbiAgfVxufVxuXG5mdW5jdGlvbiB1cGRhdGVTdGF0dXMobWVzc2FnZTogc3RyaW5nKTogdm9pZCB7XG4gIGNvbnNvbGUuaW5mbyhtZXNzYWdlKVxufVxuIgogIF0sCiAgIm1hcHBpbmdzIjogIjs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7OztBQUtPLE1BQU0sa0JBQWtCO0FBQUEsRUFDckIsWUFBZ0U7QUFBQSxFQUNoRSxjQUFjLElBQUksV0FBVyxDQUFDO0FBQUEsRUFDOUIsVUFBbUQ7QUFBQSxFQUUzRCxXQUFXLENBQUMsU0FBeUM7QUFBQSxJQUNuRCxLQUFLLFVBQVU7QUFBQSxJQUNmLEtBQUssTUFBTTtBQUFBO0FBQUEsR0FJSixrQkFBa0IsR0FBZ0Q7QUFBQSxJQUN6RSxPQUFPLE1BQU07QUFBQSxNQUVYLE1BQU0sY0FBYyxPQUFPLEtBQUssWUFBWSxDQUFDO0FBQUEsTUFDN0MsTUFBTSxhQUFhLElBQUksU0FD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QUcsQ0FBQztBQUFBLEVBQ2hDO0FBQUE7QUFFRixhQUFhO0FBQ2IsT0FBTyxpQkFBaUIsVUFBVSxZQUFZO0FBRTlDLElBQU0sTUFBTSxPQUFPLFdBQVcsSUFBSTtBQUVsQyxhQUFhLFVBQVUsWUFBWTtBQUFBLEVBQ2pDLElBQUk7QUFBQSxJQUNGLE1BQU0sY0FBYztBQUFBLElBRXBCLE1BQU0sU0FBUyxNQUFNLFVBQVUsYUFBYSxnQkFBZ0I7QUFBQSxNQUMxRCxPQUFPLEVBQUUsZ0JBQWdCLFVBQVU7QUFBQSxNQUNuQyxPQUFPO0FBQUEsTUFDUCxrQkFBa0I7QUFBQSxJQUNwQixDQUE4QjtBQUFBLElBRTlCLE1BQU0sYUFBYSxPQUFPLGVBQWUsRUFBRTtBQUFBLElBQzNDLElBQUksV0FBVyxRQUFRO0FBQUEsTUFDckIsTUFBTSxhQUFhLE1BQU0sV0FBVyxZQUFZLFVBQVU7QUFBQSxNQUMxRCxNQUFNLFdBQVcsT0FBTyxVQUFVO0FBQUEsSUFDcEM7QUFBQSxJQUVBLE1BQU0sZ0JBQWdCLElBQUksY0FBYyxRQUFRO0FBQUEsTUFDOUMsVUFBVTtBQUFBLElBQ1osQ0FBQztBQUFBLElBRUQsTUFBTSxpQkFBeUIsQ0FBQztBQUFBLElBRWhDLGNBQWMsa0JBQWtCLENBQUMsVUFBVTtBQUFBLE1BQ3pDLElBQUksTUFBTSxLQUFLLE9BQU8sR0FBRztBQUFBLFFBQ3ZCLGVBQWUsS0FBSyxNQUFNLElBQUk7QUFBQSxNQUNoQztBQUFBO0FBQUEsSUFHRixjQUFjLFNBQVMsTUFBTTtBQUFBLE1BQzNCLE1BQU0sT0FBTyxJQUFJLEtBQUssZ0JBQWdCLEVBQUUsTUFBTSxhQUFhLENBQUM7QUFBQSxNQUM1RCxNQUFNLE1BQU0sSUFBSSxnQkFBZ0IsSUFBSTtBQUFBLE1BQ3BDLE1BQU0sSUFBSSxTQUFTLGNBQWMsR0FBRztBQUFBLE1BQ3BDLEVBQUUsT0FBTztBQUFBLE1BQ1QsRUFBRSxXQUFXO0FBQUEsTUFDYixFQUFFLE1BQU07QUFBQSxNQUNSLE9BQU8sVUFBVSxFQUFFLFFBQVEsQ0FBQyxVQUFVLE1BQU0sS0FBSyxDQUFDO0FBQUE7QUFBQSxJQUdwRCxjQUFjLE1BQU07QUFBQSxJQUVwQixhQUFhLHdCQUF3QjtBQUFBLElBQ3JDLFdBQVcsVUFBVSxJQUFJLFdBQVc7QUFBQSxJQUVwQyxJQUFJLGFBQWEsVUFBVSxhQUFhO0FBQUEsTUFDdEMsYUFBYSxPQUFPO0FBQUEsSUFDdEI7QUFBQSxJQUVBLE1BQU0saUJBQWlCLFNBQVMsTUFBTTtBQUFBLE1BQ3BDLGNBQWMsS0FBSztBQUFBLEtBQ3BCO0FBQUEsSUFFRCxNQUFNLEtBQUs7QUFBQSxJQUNYLE9BQU8sS0FBSztBQUFBLElBQ1osYUFBYSxZQUFhLElBQWMsT0FBTztBQUFBO0FBQUE7QUFJbkQsU0FBUyxZQUFZLENBQUMsU0FBdUI7QUFBQSxFQUMzQyxRQUFRLEtBQUssT0FBTztBQUFBOyIsCiAgImRlYnVnSWQiOiAiMjQ3MDMzQjc5NEQ3OEEwNTY0NzU2RTIxNjQ3NTZFMjEiLAogICJuYW1lcyI6IFtdCn0=
