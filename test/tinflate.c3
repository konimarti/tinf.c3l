module tinf_test @test;

/*
 * tinf unit test
 *
 * Copyright (c) 2014-2022 Joergen Ibsen
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 *   1. The origin of this software must not be misrepresented; you must
 *      not claim that you wrote the original software. If you use this
 *      software in a product, an acknowledgment in the product
 *      documentation would be appreciated but is not required.
 *
 *   2. Altered source versions must be plainly marked as such, and must
 *      not be misrepresented as being the original software.
 *
 *   3. This notice may not be removed or altered from any source
 *      distribution.
 */

import tinf;

fn void inflate_huffman_only()
{
	// 256 zero bytes compressed using Huffman only (no match or distance codes)
	char[*] data = {
		0x05, 0xCA, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0xFF,
		0xD5, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x02
	};

	char[256] out;
	int dlen = out.len;

	out[..] = 0xFF;

	tinf::uncompress(out[..], &dlen, data[..], data.len)!!;

	assert(dlen == out.len);
	foreach(c: out) assert(c == 0);
}

fn void inflate_rle()
{
	// 256 zero bytes compressed using RLE (only one distance code)
	char[*] data = {
		0xE5, 0xC0, 0x81, 0x00, 0x00, 0x00, 0x00, 0x80, 0xA0, 0xFC,
		0xA9, 0x07, 0x39, 0x73, 0x01
	};
	char[256] out;
	int dlen = out.len;

	out[..] = 0xFF;

	tinf::uncompress(out[..], &dlen, data[..], data.len)!!;

	assert(dlen == out.len);
	foreach(c: out) assert(c == 0);
}

fn void inflate_max_matchlen()
{
	// 259 zero bytes compressed using literal/length code 285 (len 258)
	char[*] data = {
		0xED, 0xCC, 0x81, 0x00, 0x00, 0x00, 0x00, 0x80, 0xA0, 0xFC,
		0xA9, 0x17, 0xB9, 0x00, 0x2C
	};
	char[259] out;
	int dlen = out.len;

	out[..] = 0xFF;

	tinf::uncompress(out[..], &dlen, data[..], data.len)!!;

	assert(dlen == out.len);
	foreach(c: out) assert(c == 0);
}

fn void inflate_max_matchlen_alt()
{
	char[*] data = {
		0xE5, 0xCC, 0x81, 0x00, 0x00, 0x00, 0x00, 0x80, 0xA0, 0xFC,
		0xA9, 0x07, 0xB9, 0x00, 0xFC, 0x05
	};
	char[259] out;
	int dlen = out.len;

	out[..] = 0xFF;

	tinf::uncompress(out[..], &dlen, data[..], data.len)!!;

	assert(dlen == out.len);
	foreach(c: out) assert(c == 0);
}

fn void inflate_max_matchdist()
{
	char[*] data = {
		0xED, 0xDD, 0x01, 0x01, 0x00, 0x00, 0x08, 0x02, 0x20, 0xED,
		0xFF, 0xE8, 0xFA, 0x11, 0x1C, 0x61, 0x9A, 0xF7, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE0,
		0xFE, 0xFF, 0x05
	};
	char[32771] out;
	int dlen = out.len;

	out[..] = 0xFF;

	tinf::uncompress(out[..], &dlen, data[..], data.len)!!;

	assert(dlen == out.len);
	assert(out[0] == 2 && out[1] == 1 && out[2] == 0);
	for (usz i = 3; i < out.len - 3; i++) assert(out[i] == 0);
	assert(out[^3] == 2 && out[^2] == 1 && out[^1] == 0);
}

fn void inflate_code_length_codes()
{
	char[*] data = {
		0x0D, 0xC3, 0x37, 0x01, 0x00, 0x00, 0x00, 0x80, 0x20, 0xFA,
		0x77, 0x1E, 0xCA, 0x61, 0x01
	};
	char[4] out;
	int dlen = out.len;

	out[..] = 0xFF;

	tinf::uncompress(out[..], &dlen, data[..], data.len)!!;

	assert(dlen == out.len);
	foreach(c: out) assert(c == 0);
}

fn void inflate_max_codelen()
{
	char[*] data = {
		0x05, 0xEA, 0x01, 0x82, 0x24, 0x49, 0x92, 0x24, 0x49, 0x02,
		0x12, 0x8B, 0x9A, 0x47, 0x56, 0xCF, 0xDE, 0xFF, 0x9F, 0x7B,
		0x0F, 0xD0, 0xEE, 0x7D, 0xBF, 0xBF, 0x7F, 0xFF, 0xFD, 0xEF,
		0xFF, 0xFE, 0xDF, 0xFF, 0xF7, 0xFF, 0xFB, 0xFF, 0x03
	};
	char[15] out;
	int dlen = out.len;

	out[..] = 0xFF;

	tinf::uncompress(out[..], &dlen, data[..], data.len)!!;

	assert(dlen == out.len);
	foreach(i, c: out) assert(c == i);
}
