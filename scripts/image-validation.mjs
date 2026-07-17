const MAX_FILE_BYTES = 64 * 1024 * 1024;
const MAX_CONTAINER_PARTS = 100_000;
const MAX_DIMENSION = 65_535;
const MAX_PIXELS = 268_435_456;

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const PNG_BIT_DEPTHS = new Map([
  [0, new Set([1, 2, 4, 8, 16])],
  [2, new Set([8, 16])],
  [3, new Set([1, 2, 4, 8])],
  [4, new Set([8, 16])],
  [6, new Set([8, 16])],
]);
const JPEG_SOF_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
  0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

const CRC_TABLE = new Uint32Array(256);
for (let index = 0; index < CRC_TABLE.length; index += 1) {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) {
    value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
  }
  CRC_TABLE[index] = value >>> 0;
}

function crc32(buffer, start, end) {
  let crc = 0xffffffff;
  for (let offset = start; offset < end; offset += 1) {
    crc = CRC_TABLE[(crc ^ buffer[offset]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function dimensionsAreSafe(width, height) {
  return Number.isInteger(width) && Number.isInteger(height) &&
    width > 0 && height > 0 && width <= MAX_DIMENSION && height <= MAX_DIMENSION &&
    width * height <= MAX_PIXELS;
}

function isPngChunkType(buffer, offset) {
  for (let index = 0; index < 4; index += 1) {
    const byte = buffer[offset + index];
    if (!((byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a))) return false;
  }
  return buffer[offset + 2] >= 0x41 && buffer[offset + 2] <= 0x5a;
}

function validatePng(buffer) {
  if (buffer.length < 45 || !buffer.subarray(0, 8).equals(PNG_SIGNATURE)) return false;
  let offset = 8;
  let partCount = 0;
  let colorType = null;
  let sawHeader = false;
  let sawPalette = false;
  let sawImageData = false;
  let imageDataBytes = 0;
  let leftImageData = false;

  while (offset < buffer.length && ++partCount <= MAX_CONTAINER_PARTS) {
    if (buffer.length - offset < 12) return false;
    const dataLength = buffer.readUInt32BE(offset);
    const typeOffset = offset + 4;
    const dataOffset = offset + 8;
    const dataEnd = dataOffset + dataLength;
    const chunkEnd = dataEnd + 4;
    if (dataEnd < dataOffset || chunkEnd > buffer.length || !isPngChunkType(buffer, typeOffset)) return false;
    if (crc32(buffer, typeOffset, dataEnd) !== buffer.readUInt32BE(dataEnd)) return false;
    const type = buffer.subarray(typeOffset, dataOffset).toString("ascii");

    if (!sawHeader && type !== "IHDR") return false;
    if (type === "IHDR") {
      if (sawHeader || partCount !== 1 || dataLength !== 13) return false;
      const width = buffer.readUInt32BE(dataOffset);
      const height = buffer.readUInt32BE(dataOffset + 4);
      const bitDepth = buffer[dataOffset + 8];
      colorType = buffer[dataOffset + 9];
      const permittedDepths = PNG_BIT_DEPTHS.get(colorType);
      if (!dimensionsAreSafe(width, height) || !permittedDepths?.has(bitDepth)) return false;
      if (buffer[dataOffset + 10] !== 0 || buffer[dataOffset + 11] !== 0 || buffer[dataOffset + 12] > 1) return false;
      sawHeader = true;
    } else if (type === "PLTE") {
      if (sawPalette || sawImageData || dataLength < 3 || dataLength > 768 || dataLength % 3 !== 0) return false;
      if (colorType === 0 || colorType === 4) return false;
      sawPalette = true;
    } else if (type === "IDAT") {
      if (leftImageData || (colorType === 3 && !sawPalette)) return false;
      sawImageData = true;
      imageDataBytes += dataLength;
    } else {
      if (sawImageData) leftImageData = true;
      if (type === "IEND") {
        return dataLength === 0 && sawHeader && sawImageData && imageDataBytes > 0 && chunkEnd === buffer.length;
      }
      if (buffer[typeOffset] >= 0x41 && buffer[typeOffset] <= 0x5a) return false;
    }
    offset = chunkEnd;
  }
  return false;
}

function validateJpeg(buffer) {
  if (buffer.length < 10 || buffer[0] !== 0xff || buffer[1] !== 0xd8) return false;
  let offset = 2;
  let partCount = 0;
  let sawFrame = false;
  let sawScan = false;
  let sawEntropyData = false;

  while (offset < buffer.length && ++partCount <= MAX_CONTAINER_PARTS) {
    if (buffer[offset] !== 0xff) return false;
    while (offset < buffer.length && buffer[offset] === 0xff) offset += 1;
    if (offset >= buffer.length) return false;
    const marker = buffer[offset++];
    if (marker === 0x00 || marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) return false;
    if (marker === 0xd9) {
      return offset === buffer.length && sawFrame && sawScan && sawEntropyData;
    }
    if (marker === 0x01) continue;
    if (buffer.length - offset < 2) return false;
    const segmentLength = buffer.readUInt16BE(offset);
    if (segmentLength < 2 || segmentLength > buffer.length - offset) return false;
    const dataOffset = offset + 2;
    const segmentEnd = offset + segmentLength;

    if (JPEG_SOF_MARKERS.has(marker)) {
      if (sawFrame || segmentLength < 11) return false;
      const height = buffer.readUInt16BE(dataOffset + 1);
      const width = buffer.readUInt16BE(dataOffset + 3);
      const components = buffer[dataOffset + 5];
      if (!dimensionsAreSafe(width, height) || components < 1 || components > 4) return false;
      if (segmentLength !== 8 + (3 * components)) return false;
      sawFrame = true;
    }

    if (marker !== 0xda) {
      offset = segmentEnd;
      continue;
    }

    if (!sawFrame || segmentLength < 8) return false;
    const scanComponents = buffer[dataOffset];
    if (scanComponents < 1 || scanComponents > 4 || segmentLength !== 6 + (2 * scanComponents)) return false;
    sawScan = true;
    offset = segmentEnd;
    let scanBytes = 0;
    while (offset < buffer.length) {
      if (buffer[offset] !== 0xff) {
        scanBytes += 1;
        offset += 1;
        continue;
      }
      const scanMarkerStart = offset;
      while (offset < buffer.length && buffer[offset] === 0xff) offset += 1;
      if (offset >= buffer.length) return false;
      const scanMarker = buffer[offset];
      if (scanMarker === 0x00) {
        scanBytes += 1;
        offset += 1;
        continue;
      }
      if (scanMarker >= 0xd0 && scanMarker <= 0xd7) {
        offset += 1;
        continue;
      }
      offset = scanMarkerStart;
      break;
    }
    if (scanBytes === 0) return false;
    sawEntropyData = true;
  }
  return false;
}

function readUInt24LE(buffer, offset) {
  return buffer[offset] | (buffer[offset + 1] << 8) | (buffer[offset + 2] << 16);
}

function validateVp8Dimensions(buffer, offset, length) {
  if (length <= 10 || (buffer[offset] & 1) !== 0) return false;
  const frameTag = readUInt24LE(buffer, offset);
  const firstPartitionLength = frameTag >>> 5;
  if (((frameTag >>> 1) & 0x07) > 3 || firstPartitionLength <= 7 || 3 + firstPartitionLength > length) return false;
  if (buffer[offset + 3] !== 0x9d || buffer[offset + 4] !== 0x01 || buffer[offset + 5] !== 0x2a) return false;
  return dimensionsAreSafe(buffer.readUInt16LE(offset + 6) & 0x3fff, buffer.readUInt16LE(offset + 8) & 0x3fff);
}

function validateVp8lDimensions(buffer, offset, length) {
  if (length <= 5 || buffer[offset] !== 0x2f) return false;
  const bits = buffer.readUInt32LE(offset + 1);
  if ((bits >>> 29) !== 0) return false;
  return dimensionsAreSafe((bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1);
}

function validateVp8xDimensions(buffer, offset, length) {
  if (length !== 10 || (buffer[offset] & 0xc1) !== 0) return false;
  if (buffer[offset + 1] !== 0 || buffer[offset + 2] !== 0 || buffer[offset + 3] !== 0) return false;
  return dimensionsAreSafe(readUInt24LE(buffer, offset + 4) + 1, readUInt24LE(buffer, offset + 7) + 1);
}

function validateAnimationFrame(buffer, offset, length) {
  if (length < 26) return false;
  if (!dimensionsAreSafe(readUInt24LE(buffer, offset + 6) + 1, readUInt24LE(buffer, offset + 9) + 1)) return false;
  if ((buffer[offset + 15] & 0xfc) !== 0) return false;
  let nestedOffset = offset + 16;
  const frameEnd = offset + length;
  let partCount = 0;
  let sawAlpha = false;
  let sawImage = false;
  while (nestedOffset < frameEnd && ++partCount <= MAX_CONTAINER_PARTS) {
    if (frameEnd - nestedOffset < 8) return false;
    const type = buffer.subarray(nestedOffset, nestedOffset + 4).toString("ascii");
    const dataLength = buffer.readUInt32LE(nestedOffset + 4);
    const dataOffset = nestedOffset + 8;
    const dataEnd = dataOffset + dataLength;
    const paddedEnd = dataEnd + (dataLength & 1);
    if (dataEnd < dataOffset || paddedEnd > frameEnd) return false;
    if ((dataLength & 1) && buffer[dataEnd] !== 0) return false;
    if (type === "ALPH") {
      if (sawAlpha || sawImage || dataLength === 0) return false;
      sawAlpha = true;
    } else if (type === "VP8 ") {
      if (sawImage || !validateVp8Dimensions(buffer, dataOffset, dataLength)) return false;
      sawImage = true;
    } else if (type === "VP8L") {
      if (sawAlpha || sawImage || !validateVp8lDimensions(buffer, dataOffset, dataLength)) return false;
      sawImage = true;
    } else {
      return false;
    }
    nestedOffset = paddedEnd;
  }
  return nestedOffset === frameEnd && sawImage;
}

function validateWebp(buffer) {
  if (buffer.length < 20 || buffer.subarray(0, 4).toString("ascii") !== "RIFF") return false;
  if (buffer.subarray(8, 12).toString("ascii") !== "WEBP") return false;
  if (buffer.readUInt32LE(4) + 8 !== buffer.length) return false;
  let offset = 12;
  let partCount = 0;
  let firstType = null;
  let sawExtendedHeader = false;
  let extendedFlags = 0;
  let sawImageData = false;
  let sawAnimationControl = false;
  let sawAnimationFrame = false;

  while (offset < buffer.length && ++partCount <= MAX_CONTAINER_PARTS) {
    if (buffer.length - offset < 8) return false;
    const type = buffer.subarray(offset, offset + 4).toString("ascii");
    const dataLength = buffer.readUInt32LE(offset + 4);
    const dataOffset = offset + 8;
    const dataEnd = dataOffset + dataLength;
    const paddedEnd = dataEnd + (dataLength & 1);
    if (dataEnd < dataOffset || paddedEnd > buffer.length) return false;
    if ((dataLength & 1) && buffer[dataEnd] !== 0) return false;
    firstType ??= type;

    if (type === "VP8X") {
      if (sawExtendedHeader || partCount !== 1 || !validateVp8xDimensions(buffer, dataOffset, dataLength)) return false;
      sawExtendedHeader = true;
      extendedFlags = buffer[dataOffset];
    } else if (type === "VP8 ") {
      if (sawImageData || !validateVp8Dimensions(buffer, dataOffset, dataLength)) return false;
      sawImageData = true;
    } else if (type === "VP8L") {
      if (sawImageData || !validateVp8lDimensions(buffer, dataOffset, dataLength)) return false;
      sawImageData = true;
    } else if (type === "ANIM") {
      if (!sawExtendedHeader || sawAnimationControl || dataLength !== 6 || (extendedFlags & 0x02) === 0) return false;
      sawAnimationControl = true;
    } else if (type === "ANMF") {
      if (!sawExtendedHeader || !sawAnimationControl || !validateAnimationFrame(buffer, dataOffset, dataLength)) return false;
      sawAnimationFrame = true;
    }
    offset = paddedEnd;
  }

  if (offset !== buffer.length || !["VP8 ", "VP8L", "VP8X"].includes(firstType)) return false;
  if (firstType === "VP8X") {
    if ((extendedFlags & 0x02) !== 0) return sawAnimationControl && sawAnimationFrame && !sawImageData;
    return !sawAnimationControl && !sawAnimationFrame && sawImageData;
  }
  return !sawExtendedHeader && sawImageData;
}

export function validateImageContainer(input, extension) {
  try {
    const buffer = Buffer.isBuffer(input)
      ? input
      : input instanceof Uint8Array
        ? Buffer.from(input.buffer, input.byteOffset, input.byteLength)
        : null;
    if (!buffer || buffer.length === 0 || buffer.length > MAX_FILE_BYTES) return false;
    const normalized = String(extension).toLowerCase();
    if (normalized === ".png") return validatePng(buffer);
    if (normalized === ".jpg" || normalized === ".jpeg") return validateJpeg(buffer);
    if (normalized === ".webp") return validateWebp(buffer);
    return false;
  } catch {
    return false;
  }
}
