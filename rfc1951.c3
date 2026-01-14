module rfc;
import std::io, std::encoding, std::collections, tinf;

const BITS = 8;
struct DynamicBitList (Printable)
{
	List{char} list;
	usz pos;
}

fn void DynamicBitList.init(&self, Allocator allocator) => self.list.init(allocator);
fn void DynamicBitList.tinit(&self) => self.init(tmem);
fn void DynamicBitList.free(&self) => self.list.free();
fn usz? DynamicBitList.to_format(&self, Formatter *f) @dynamic => @pool()
{
	return f.printf("%s", hex::tencode(self.list.array_view()));
}

enum BitState { UNSET, SET }
fn void DynamicBitList.push_bit(&self, BitState bit)
{
	usz index = self.pos / BITS;
	usz offset = self.pos % BITS;
	if (index >= self.list.len()) self.list.push(0);

	char b = self.list[index];
	b = (bit == SET) ? b | (1UL << offset) : b & ~(+1UL << offset);

	self.list[index] = b;
	self.pos++;
}

<*
 @require pos >= 0 && pos <= 32 : "Pos needs to be between 0 and 32."
*>
macro BitState get_bit_state(uint b, isz pos)
{
	return (b & (1UL<<pos)) != 0 ? BitState.SET : BitState.UNSET;
}

<*
 @param bits     : "Bits to be pushed"
 @param num_bits : "Number of bits to push"
 @require num_bits >= 1  : "Number of bits must be at least 1"
 @require num_bits <= 32 : "Number of bits can not be larger than 32"
*>
fn void DynamicBitList.push(&self, uint bits, isz num_bits)
{
	// Simple but slow:
	// for (isz i = 0; i < num_bits; i++)
	// {
	// 	self.push_bit(get_bit_state(bits, i));
	// }

	// A bit more complex, but ~4x faster:
	isz consumed, offset, n;

	bits &= (1U << num_bits) - 1;

	consumed = 0;
	offset = self.pos % BITS;
	if (offset > 0)
	{
		n = BITS - offset;
		if (n > num_bits) n = num_bits;
		self.list[^1] |= (char)((bits<<offset) & 0xff);
		bits >>= n;
		consumed += n;
		num_bits -= n;
	}

	while (num_bits > 0)
	{
		self.list.push((char)(bits & 0xFF));
		n = (num_bits > BITS) ? BITS : num_bits;
		bits >>= n;
		consumed += n;
		num_bits -= n;
	}

	self.pos += consumed;
}

fn void test_bit_push_bench() @benchmark
{
	DynamicBitList bs;
	bs.init(mem);
	defer bs.free();

	for (uint i = 0; i < (1<<9); i++)
	{
		bs.push(0b1010011, 7);
	}
}


import std::bits;
<*
 @require len < 16
*>
fn ushort reverse_bits(ushort b, int len) @inline
{
	ushort v = b << (16 - (char)len);
	ushort r = bits::reverse(v);
	return r;
}

fn void main() => @pool()
{
	DynamicBitList bs;
	bs.tinit();

	bs.push(0b101, 3);
	io::printfn("%s", bs);

	bs.push(0b1001001, 7);
	io::printfn("%s", bs);

	bs.push(0b101, 3);
	io::printfn("%s", bs);

	foreach (i, b: bs.list) io::printfn("%d\t%08b", i, b);

	// test_huff_tree();
	// test_package_merge();
	test_lz77();
	// no_compression();
	fixed_huff();
	// dynamic_huff();
}

// macro void? write_le_16(stream, ushort s)
// {
// 	stream.write_byte((char)s)!;
// 	stream.write_byte((char)(s >> 8))!;
// }

import std::math;
fn void no_compression() => @pool()
{
	io::printn("-- no compression --");
	// char[] input = "hello world";
	char[] input = "12";

	// char[1024] input;
	// foreach (i, &e : input) *e = (char)(i % 255);

	char[] encoded = nocomp_encode(input[..], tmem);
	io::printfn("%s", hex::tencode(encoded));

	verify(encoded, input[..], "no_comp");
}

<*
 TODO: Enforce max block size of 65'535 as defined in the RFC.
*>
fn char[] nocomp_encode(char[] input, Allocator allocator) => @pool()
{
	DynamicBitList bs;
	bs.tinit();

	// Set Block header
	// Push BFINAL (0b1) and BTYPE (0b00) as 0x001 [read from right to left]
	bs.push(0b001, 8);

	// Encode len (deflate rfc packes data elements into bytes as lsb) If
	// input.len does not fit an ushort, we have to create multiple blocks
	ushort len = (ushort)input.len;
	bs.push((char)len, 8);
	bs.push((char)(len>>8), 8);

	ushort nlen = ~len;
	bs.push((char)nlen, 8);
	bs.push((char)(nlen>>8), 8);

	// Encode data
	foreach(i, c: input)
	{
		bs.push(c, 8);
	}

	foreach (i, b : bs.list)
	{
		io::printfn("bytes %2d: 0x%02x 0b%08b", i, b, b);
	}

	return bs.list.to_array(allocator);
}

fn void dynamic_huff() => @pool()
{
	io::printn("-- dynamic huffman encoding --");

	// Input string to be deflated
	char[] s = "hello world";

	// Calculate frequencies and bit lengths
	int[257] freqs;
	foreach (c: s) freqs[c]++;
	freqs[256]++; // don't forget end of block marker

	char[] bit_len = package_merge(freqs[..], 15, tmem);
	// char[] bit_len = huff_bit_counts(freqs[..], 15);

	// Generate the fixed Huffman codes
	ushort[] huff_codes = gen_huff(bit_len[..]);

	// Distance codes bit_len
	char[*] dist_len = {
		[0] = 0, // one distance code with zero bits -> no distance code used
	};

	// Generate the distance codes
	ushort[] dist_codes = gen_huff(dist_len[..]);

	// Encode string
	char[] encoded = dynamic_huff_encode(s,
			huff_codes[:257], bit_len[:257],
			dist_codes, dist_len[..],
		tmem);
	io::printfn("%s", hex::tencode(encoded));

	verify(encoded, s, "dynamic_huff");
}

fn char[] dynamic_huff_encode(char[] input, ushort[] codes, char[] len,
					ushort[]dist_codes, char[] dist_len,
			Allocator allocator) => @pool()
{
	// Create code-length Huff codes
	char[] hc_order = {
		16, 17, 18,  0,  8,
		 7,  9,  6, 10,  5,
		11,  4, 12,  3, 13,
	 	 2, 14,  1, 15,
	 };

	// Record bitlen frequencies
	uint[*] freqs = { [0..18] = 0 };
	foreach (l: len)      freqs[l]++;
	foreach (l: dist_len) freqs[l]++;

	io::printfn("frequencies");
	foreach (i, freq: freqs)
	{
		io::printfn("%d\t%d", i, freq);
	}

	io::printfn("freqs       : %s", freqs);
	// Create code-length Huff codes
	char[] hc_len = package_merge(freqs[..], 5, tmem);
	io::printfn("counts (pm)  : %s", hc_len);
	// hc_len = huff_bit_counts(freqs[..], 5);
	// io::printfn("counts (tree): %s", hc_len);
	ushort[] hc_codes = gen_huff(hc_len);

	foreach (i, code : hc_codes)
	{
		io::printfn("hc_codes %2d %08b (len:%d)", i, hc_codes[i], hc_len[i]);
	}

	DynamicBitList bs;
	bs.tinit();

	// Set Block header
	// Push BFINAL (0b1) and BTYPE (0b10) as 0x101 [read from right to left]
	bs.push(0b101, 3);

	// Push 5 bits HLIT (# of literal/length codes - 257)
	bs.push(codes.len-257, 5);

	// Push 5 bits HDIST (# of distance codes - 1)
	bs.push(dist_codes.len-1, 5);

	// Push 4 bits HCLEN (# of code length codes - 4)
	bs.push(hc_codes.len-4, 4);

	// Assume for now that we use all 19 codes with a code bit length of 3
	// bits; ensure that they are written in the expected order
	for (usz i = 0; i < 19; i++)
	{
		io::printfn("having: %d -> %d -> %d", i, hc_order[i], hc_len[i]);
		bs.push(hc_len[hc_order[i]], 3);
	}

	// Now save the literal/length tree, hc-encoded
	foreach(l: len)
	{
		bs.push(hc_codes[l], hc_len[l]);
	}

	// Now save the distance/tree, hc-encoded
	foreach(l: dist_len)
	{
		bs.push(hc_codes[l], hc_len[l]);
	}

	// And finally the compressed data
	foreach(c: input)
	{
		bs.push(codes[c], len[c]);
	}

	// Add end of block code 256
	bs.push(codes[256], len[256]);

	return bs.list.to_array(allocator);
}

fn void fixed_huff() => @pool()
{
	io::printn("-- fixed huffman encoding --");

	// Fixed Huffman codes bit_len
	char[*] bit_len = {
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	};

	// Generate the fixed Huffman codes
	ushort[] huff_codes = gen_huff(bit_len[..]);

	// Distance codes dist_len
	char[*] dist_len = {
		[  0..32] = 5,
	};

	// Generate the distance codes
	ushort[] dist_codes = gen_huff(dist_len[..]);

	// Input string to be deflated
	char[] s = "hello world wor";
	foreach (c: s) io::printfn("code[%c] = %08b", c, huff_codes[c]);

	// Encode string
	char[] encoded = fixed_huff_encode(s, huff_codes, bit_len[..], dist_codes, dist_len[..], tmem);
	io::printfn("%s", hex::tencode(encoded));

	verify(encoded, s, "fixed_huff");
}

fn void verify(char[] encoded, char[] input, String test_name)
{
	// Decompress with inflate
	char[1024] output;
	if (catch err = inflate::uncompress(output[..], encoded))
	{
		io::printfn("rfc: Failed in: %s", test_name);
		abort();
	}
	// io::printfn("uncompressed: '%s'", (String)output[..]);

	String want = (String)input[:input.len];
	String got = (String)output[:input.len];
	assert(want == got, "%s failed: want: %s, got: %s", test_name, want, got);

	io::printfn("SUCCESS: %s", test_name);
}

<*
 Encode char[] with the provided Huffman codes and bit lengths.
 @require codes.len == len.len
*>
fn char[] fixed_huff_encode(char[] input, ushort[] codes, char[] len,
	ushort[] dist_codes, char[] dist_len, Allocator allocator) => @pool()
{
	DynamicBitList bs;
	bs.tinit();

	// Set Block header
	// Push BFINAL (0b1) and BTYPE (0b01) as 0x011 [read from right to left]
	bs.push(0b011, 3);

	usz x;
	foreach(token: lz77_tokenize(tmem, (String)input))
	{
		io::printfn("token: %s", token);
		switch (token.type)
		{
			case LITERAL:
				char c = token.lit;
				bs.push(codes[c], len[c]);

			case MATCH:
				// Write length code.
				if (try idx = huff_index_lookup(&len_base, token.length()))
				{
					// Write distance code.
					bs.push(codes[257+idx], len[257+idx]);

					// Write extra bit.
					if (len_extra[idx])
					{
						bs.push(token.length()-len_base[idx], len_extra[idx]);
					}
				}

				// Write distance code.
				if (try idx = huff_index_lookup(&dist_base, token.offset()))
				{
					// Write distance code.
					bs.push(dist_codes[idx], dist_len[idx]);

					// Write extra bit.
					if (dist_extra[idx])
					{
						bs.push(token.offset()-dist_base[idx], dist_extra[idx]);
					}
				}

			default: unreachable("invalid token type");
		}
	}

	// Add end of block code 256
	bs.push(codes[256], len[256]);

	foreach (i, b : bs.list)
	{
		io::printfn("bytes %2d: 0x%02x 0b%08b", i, b, b);
	}

	return bs.list.to_array(allocator);
}



<* RFC Section 3.2.5 *>
uint[*] len_base = {
	3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17,
	19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
	99, 115, 131, 163, 195, 227, 258,
};

<* RFC Section 3.2.5 *>
char[*] len_extra = {
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1,
	2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
	5, 5, 5, 5, 0,
};

<* RFC Section 3.2.5 *>
uint[*] dist_base = {
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97,
	129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
	4097, 6145, 8193, 12289, 16385, 24577,
	32768 /* range end marker */,
};

<* RFC Section 3.2.5 *>
char[*] dist_extra = {
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4,
	5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
	11, 11, 12, 12, 13, 13,
};

<*
 Returns the index for the given base values.
*>
fn usz? huff_index_lookup(uint[] base, uint off)
{
	for (usz i = 0; i < base.len - 1; i++)
	{
		if (off < base[i+1]) return i;
	}
	return NOT_FOUND?;
}

<*
 RFC 1951, Section 3.2.2. Use of Huffman coding in the "deflate" format
 require bit_len.len == 288 || bit_len.len == 19: "Code bit_len array must contain exactly 288 or 19 elements"

 @param bit_len : "Array with bit bit_len of Huffman codes"
 @return "Huffman codes (bits reversed)"
*>
fn ushort[] gen_huff(char[] bit_len)
{
	// Toy model in RFC:
	// int[*] bit_len = { 3, 3, 3, 3, 3, 2, 4, 4 };
	// char[*] sym = "ABCDEFGH";

        // 1)  Count the number of codes for each code length.  Let
        //     bl_count[N] be the number of codes of length N, N >= 1.

	HashMap{char, ushort} bl_count;
	bl_count.tinit();
	foreach (len: bit_len) bl_count[len] += 1;
	// io::printfn("bl_count[N]: %s", bl_count);

        // 2)  Find the numerical value of the smallest code for each
        //     code length:

	const MAX_BITS = 32; // ??

	List{ushort} next_code;
	next_code.tinit();
	next_code.push(0); // Move index to 1

	ushort code = 0;
	bl_count[0] = 0;
	for (char bits = 1; bits <= MAX_BITS; bits++)
	{
	        code = (code + bl_count[bits-1] ?? 0) << 1;
	        next_code.push(code);
	}
	// io::printfn("next_code[N]: %s", next_code);

        // 3)  Assign numerical values to all codes, using consecutive
        //     values for all codes of the same length with the base
        //     values determined at step 2. Codes that are never used
        //     (which have a bit length of zero) must not be assigned a
        //     value.

	ushort[] codes = mem::temp_array(ushort, bit_len.len);
	foreach (i, len: bit_len)
	{
		if (len == 0) continue;
		// io::printfn("%4d\t%d\t%0*b", i, len, len, next_code[len]);
		codes[i] = reverse_bits(next_code[len], len);
		next_code[len]++;
	}
	return codes;
}

/*
 3.2.3 Details of block format

 first bit	BFINAL
 next 2 bits	BTYPE

 BFINAL only set if is the last block of the data set.

 BTYPE specifies how the data are compressed:

 	00 - no compression
	01 - fixed Huffman codes
	10 - dynamic Huffman codes
	11 - reserved (error)

3.2.4. Non-compressed blocks (BTYPE=00)

         Any bits of input up to the next byte boundary are ignored.
         The rest of the block consists of the following information:

              0   1   2   3   4...
            +---+---+---+---+================================+
            |  LEN  | NLEN  |... LEN bytes of literal data...|
            +---+---+---+---+================================+

         LEN is the number of data bytes in the block.  NLEN is the
         one's complement of LEN.
*/

fn void test_huff_tree()
{
	uint[] freqs = {4,2,0,3,2,0};
	char[] counts = huff_bit_counts(freqs, 15);
	io::printfn("huff_tree_bit counts: %s", counts);

	char[] pm_counts = package_merge(freqs, 15, tmem);
	io::printfn("package-merge counts: %s", pm_counts);

	ushort[] codes = gen_huff(counts[..]);

	foreach (i, hcode : codes)
	{
		io::printfn("%d\t%08b", freqs[i], hcode);
	}
}

import std::collections::priorityqueue;
enum NodeType { LEAF, DUMMY, INTERNAL }
struct Node
{
	NodeType type;
	uint freq;
	usz pos;
	Node *left;
	Node *right;
}

fn bool Node.less(&self, Node* b) => self.freq < b.freq;

fn Node* make_node(NodeType type, uint freq, usz pos, Allocator allocator = tmem)
{
	return allocator::new(allocator, Node, { type, freq, pos, null, null });
}

// Create a huffman tree from a set of frequencies. Ensure that the huffman
// codes are not longer than max_bits (adding max-bits - 1 dummy nodes)? Not
// sure if that's the case here.
// Returning the bit lengths for the huffman codes.
<*
 @require max_bits >= 2 && max_bits < 16
*>
fn char[] huff_bit_counts(uint[] freqs, char max_bits)
{
	PriorityQueue{Node*} heap;
	heap.tinit();

	// Fill heap with freqs
	foreach (i, freq : freqs)
	{
		if (freq == 0) continue;
		heap.push(make_node(NodeType.LEAF, freq, i));
	}
	// Add max_bits - 1 dummy nodes
	for (usz i = 0; i < max_bits - 1; i++)
	{
		heap.push(make_node(NodeType.DUMMY, 1<<20, 0));
	}

	while (heap.len() > 1)
	{
		Node *a = heap.pop()!!;
		Node *b = heap.pop()!!;
		uint new_freq = a.freq + b.freq;
		Node *new_node = make_node(NodeType.INTERNAL, new_freq, 0);
		io::printfn("combine %d + %d = %d", a.freq, b.freq, new_freq);
		new_node.left = a;
		new_node.right = b;
		heap.push(new_node);
	}

	char[] counts = allocator::new_array(tmem, char, freqs.len);

	// heap.first() points to root node
	huff_tree_traverse(heap.first()!!, counts, 0);

	// io::printfn("huff_bit_counts: counts=%s", counts);

	// Remove depth from dummy node
	char off = (char)(math::log2(max_bits - 1)+0.5); // TODO: math::ceil
	foreach (&count: counts) if (*count > off) *count -= off;

	// io::printfn("huff_bit_counts: counts=%s", counts);

	return counts;
}

fn void huff_tree_traverse(Node *n, char[] counts, char depth)
{
	if (n.type == LEAF)
	{
		assert(counts[n.pos] == 0);
		counts[n.pos] = depth;
		return;
	}

	// Recurse through dummies and internal
	if (n.left != null)  huff_tree_traverse(n.left, counts, depth+1);
	if (n.right != null) huff_tree_traverse(n.right, counts, depth+1);
}

fn void test_package_merge()
{
	uint[] freqs = {4,4,4,0,3,2,1};
	char[] counts = package_merge(freqs, 5, tmem);
	assert(freqs.len == counts.len);
	io::printfn("counts: %s", counts);

	ushort[] codes = gen_huff(counts);
	foreach (i, code : codes)
	{
		io::printfn("%d\t%08b", freqs[i], code);
	}
}

import std::sort;

struct Mapping (Printable)
{
	usz index;
	uint freq;
}
fn bool Mapping.less(&self, Mapping other) => self.freq < other.freq;
fn usz? Mapping.to_format(&self, Formatter *f) @dynamic => f.printf("(%d)", self.freq);

<*
 Compute length-limited prefix code lengths based on Larmore/Hirschberg's
 package-merge algorithm.

 Based on the C implementation from Stephan Brumme (2021):
 https://create.stephan-brumme.com/length-limited-prefix-codes/
*>
fn char[] package_merge(uint[] freqs, uint max_bits, Allocator allocator) => @pool()
{
	List{Mapping} mappings;
	mappings.tinit();

	// copy frequencies and remove 0's
	usz num_codes;
	foreach (i, freq: freqs)
	{
		if (freq == 0) continue;
		mappings.push({i, freq});
		num_codes++;
	}

	// Sort in ascending order
	// io::printfn("before: %s", mappings);
	sort::quicksort(mappings.array_view());
	// io::printfn("after:  %s", mappings);

	uint[] hist = mem::temp_array(uint, num_codes);
	foreach (i, m: mappings) hist[i] = m.freq;

	// One or two codes are encoded with a single bit
	if (num_codes <= 2)
	{
		char[] len = mem::temp_array(char, num_codes);
		len[0] = 1;
		return len;
	}

	// Require two scratch buffers to process iterations and some bitmasks
	usz max_elements = 2 * num_codes;
	uint[] current   = mem::temp_array(uint, max_elements);
	uint[] previous  = mem::temp_array(uint, max_elements);
	ulong[] is_merged = mem::temp_array(ulong, max_elements);

	uint[] temp   = mem::temp_array(uint, max_elements);

	// Initial value of "previous" is the histogram
	previous[:num_codes] = hist[:num_codes];

	usz num_previous = num_codes;

	// Keep track which packages are merged in a compact bit masks
	// If package p was merged in iteration i,
	// then (is_merged[p] & (1<<i)) != 0
	is_merged[:max_elements] = 0;

	// Last 2 packages are irrelevant
	uint num_relevant = 2 * (uint)num_codes - 2;

	// //////////////////////////////////////////////////////////////////////
	// iterate through potential bit lengths while packaging and merging pairs
	// (step 1 of the algorithm)
	// - the histogram is sorted (prerequisite of the function)
	// - the output must be sorted, too
	// - thus we have to copy the histogram and every and then insert a new package
	// - the code keeps track of the next package and compares it to
	//   the next item to be copied from the history
	// - the smaller value is chosen (if equal, the histogram is chosen)
	// - a bitmask named isMerged is used to keep track which items were packages
	// - repeat until the whole histogram was copied and all packages inserted

	ulong mask = 1;
	uint bits;
	for (bits = max_bits - 1; bits > 0; bits--)
	{
		num_previous &= ~1;

		current[0] = hist[0];
		current[1] = hist[1];
		uint sum = current[0] + current[1];

		// copy histogram and insert merged sums
		uint num_current = 2;
		uint num_hist = num_current;
		uint num_merged = 0;

		while (true)
		{
			if (num_hist < num_codes && hist[num_hist] <= sum)
			{
				current[num_current++] = hist[num_hist++];
				continue;
			}

			is_merged[num_current] |= mask;
			current[num_current] = sum;
			num_current++;

			num_merged++;
			if (num_merged * 2 >= num_previous) break;

			sum = previous[num_merged * 2] + previous[num_merged * 2 + 1];
		}

		while (num_hist < num_codes) current[num_current++] = hist[num_hist++];

		mask <<= 1;

		if (num_previous >= num_relevant)
		{
			char keep_going = 0;
			for (uint i = num_relevant - 1; i > 0; i--)
			{
				if (previous[i] != current[i])
				{
					keep_going++;
					break;
				}
			}
			if (keep_going == 0) break;
		}

		// swap prev and current
		// @swap(previous, current);
		temp[..] = previous[..];
		previous[..] = current[..];
		current[..] = temp[..];

		num_previous = num_current;
	}

	mask >>= 1;

	// //////////////////////////////////////////////////////////////////////
	// tracking all merges will produce the code lengths
	// (step 2 of the algorithm)
	// - analyze each bitlength's mask in isMerged:
	//   * a "pure" symbol => increase bitlength of that symbol
	//   * a merged code   => just increase counter
	// - stop if no more merged codes found
	// - if m merged codes were found then only examine
	//   the first 2*m elements in the next iteration
	//   (because only they formed these merged codes)

	// Reuse hist array for code lengths
	hist[..] = 0;

	uint num_analyze = num_relevant;
	while (mask != 0)
	{
		uint num_merged = 0;
		hist[0]++;
		hist[1]++;

		usz symbol = 2;
		for (usz i = symbol; i < num_analyze; i++)
		{
			if ((is_merged[i] & mask) == 0)
			{
				hist[symbol]++;
				symbol++;
			}
			else
			{
				num_merged++;
			}
		}

		num_analyze = 2 * num_merged;

		mask >>= 1;
	}

	// Last iterations can't have any merges
	for (usz i = 0; i < num_analyze; i++) hist[i]++;

	// Remap to correct indices
	char[] code_length = allocator::new_array(allocator, char, freqs.len);
	foreach (i, m: mappings)
	{
		code_length[m.index] = (char)hist[i];
	}

	return code_length;
}

fn void test_package_merge_fn() @test => @pool()
{
	uint[] freqs = {4,4,4,0,3,2,1};
	char[] counts = package_merge(freqs, 5, tmem);
	assert(freqs.len == counts.len);
	assert(counts == {2,2,2,0,3,4,4});
}

/*

Lempel-Ziv Compression

*/

enum TokenType : inline char
{
	INVALID,
	LITERAL,
	MATCH
}

const ushort MIN_MATCH_LEN   = 3;
const ushort MAX_MATCH_LEN   = 258;
const ushort MAX_WINDOW_SIZE = 1 << 15;
const uint   MIN_OFFSET_LEN  = 3;

bitstruct Token (Printable) : uint @bigendian @overlap
{
	TokenType type : 0..2;   //  2 bits: 0 = INVALID, 1 = LITERAL, 2 = MATCH, 3 = EOF
	char      len  : 3..10;  //  8 bits: len = length - MIN_MATCH_LENGTH
	uint      off  : 11..31; // 20 bits: off = offset - MIN_OFFSET_SIZE
	char      lit  : 24..31; //  8 bits: store literal
}

fn ushort Token.length(&self) => MIN_MATCH_LEN + (ushort)self.len;
fn uint Token.offset(&self) => MIN_OFFSET_LEN + self.off;

<*
 @require length >= MIN_MATCH_LEN
 @require offset >= MIN_OFFSET_LEN
*>
fn Token make_match(ushort length, uint offset)
{
	return (Token){
		.type = MATCH,
		.len = (char)(length - MIN_MATCH_LEN),
		.off = offset - MIN_OFFSET_LEN,
	};
}
fn Token make_literal(char literal) => (Token){ .type = LITERAL, .lit = literal };

fn usz? Token.to_format(&self, Formatter *f) @dynamic
{
	switch (self.type)
	{
		case LITERAL: return f.printf("LITERAL<%c>", self.lit);
		case MATCH:   return f.printf("MATCH<%d:%d>", self.offset(), self.length());
		default: unreachable("invalid token type");
	}
}

const uint HASH_MASK = (1U << 16) - 1;
alias HashKey  = ushort;
fn HashKey lz77_hash(char[3] b)
{
	uint x = (b[0] << 16) | (b[1] << 8) | b[2];
	x ^= x >> 12;
	x ^= x << 5;
	return (HashKey)(x & HASH_MASK);
}

alias HashChain = LinkedList{ isz };
alias MatchPair = Pair{uint, ushort};

<*
 @param [&inout] chain : "Chained hash list storing positions in s"
 @param s              : "Input data string"
 @param i              : "Current index in s"
*>
fn MatchPair find_max_match(HashChain *chain, String s, usz i) @private @inline
{
	ushort max_match_len, len;
	uint max_match_off, offset;

	max_match_len = 0;
	max_match_off = 0;

	linkedlist::Node{isz} *node, temp;
	node = chain._first;
	while (node != null)
	{
		isz hash_pos = node.value;
		assert(i >= hash_pos);

		offset = (uint)(i - hash_pos);
		if (offset > MAX_WINDOW_SIZE)
		{
			// Remove this node from the hash chain.
			temp = node;
			node = node.next;
			chain.unlink(temp);
			continue;
		}

		// Find max match length.
		len = 3;
		while ((i + len) < s.len && s[hash_pos+len] == s[i+len])
		{
			len++;
		}

		if (len > max_match_len ||
			(len == max_match_len && offset < max_match_off))
		{
			max_match_len = len;
			max_match_off = offset;
		}

		node = node.next;
	}

	return {max_match_off, (max_match_len > MAX_MATCH_LEN) ? MAX_MATCH_LEN : max_match_len};
}

fn HashChain make_hash_chain(Allocator allocator, usz... elements)
{
	HashChain chain;
	chain.init(allocator);
	chain.push_all(elements);
	return chain;
}

fn Token[] lz77_tokenize(Allocator allocator, String s) => @pool()
{
	usz i;
	uint offset;
	ushort len;

	MatchPair match, alternative;
	HashMap{ HashKey, HashChain } hash;
	hash.tinit();

	List{Token} tokens;
	tokens.tinit();

	// Prepare hash and process input.
	for (i = 0; i < s.len - 2; i++)
	{
		HashKey key = lz77_hash(s[i:3]);
		if (!hash.has_key(key))
		{
			// No hit: it's a literal!
			// Emit literal token.
			tokens.push(make_literal(s[i]));

			// Store current hash in a new hash chain.
			hash.set(key, make_hash_chain(tmem, i));
			continue;
		}

		// We have a hit: Find largest match in chain.
		HashChain *chain = hash.get_ref(key)!!;
		match = find_max_match(chain, s, i);

		// Save index in hash chain.
		chain.push_front(i);

		// If next hash has a longer match, then emit current literal
		// and go to next iteration.
		if (i + 3 + 1 < s.len)
		{
			// "Lazy Matching".
			if (try alt_chain = hash.get_ref(lz77_hash(s[i+1:3])))
			{
				alternative = find_max_match(alt_chain, s, i+1);
				if (alternative.second > match.second) match = {};
			}
		}

		offset = match.first;
		len    = match.second;
		if (len > 0 && offset > 0)
		{
			// Emit match token.
			tokens.push(make_match(len, offset));

			usz end = i + len - 1L; // -1 because of increment in for-loop
			for (; i < end; i++)
			{
				if (i + 3 >= s.len) continue;
				HashKey k = lz77_hash(s[i:3]);
				if (try alt_chain = hash.get_ref(k))
				{
					alt_chain.push_front(i);
					continue;
				}
				hash.set(key, make_hash_chain(tmem, i));
			}
		}
		else
		{
			// Emit literal token.
			tokens.push(make_literal(s[i]));
		}
	}

	// Emit remaining literal tokens.
	while (i < s.len)
	{
		tokens.push(make_literal(s[i++]));
	}

	return tokens.to_array(allocator);
}

fn char[] lz77_construct(Allocator allocator, Token[] tokens) => @pool()
{
	DString buf;
	buf.tinit();

	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL:
				buf.append_char(token.lit);
			case MATCH:
				usz start = buf.len() - token.offset();
				usz end   = start + token.length();
				for (usz i = start; i < end; i++)
				{
					buf.append_char(buf[i]);
				}
			default:
				continue;
		}
	}

	return buf.copy_str(allocator);
}

fn void test_lz77()
{
	// String s = "hello world world hello";
	String s = "aaa aaaa aaaa";
	Token[] tokens = lz77_tokenize(tmem, s);

	io::printfn("%s", tokens);

	String r = (String)lz77_construct(tmem, tokens);
	io::printfn("construct: '%s'", r);
	assert(s == r, "want: '%s', got: '%s'", s, r);
}

