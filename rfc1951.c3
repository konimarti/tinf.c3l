module rfc;
import std::io, std::encoding, std::collections, tinf;

struct DynamicBitList
{
	List{char} list;
	usz pos;
}

fn void DynamicBitList.init(&self, Allocator allocator) => self.list.init(allocator);
fn void DynamicBitList.tinit(&self) => self.init(tmem);
fn void DynamicBitList.free(&self) => self.list.free();

enum BitState { UNSET, SET }
fn void DynamicBitList.push_bit(&self, BitState bit)
{
	usz index = self.pos / 8;
	usz offset = self.pos % 8;
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
 @param b        : "Bits to be pushed"
 @param num_bits : "Number of bits to push"
 @param lsb      : "Order from which side to start pushing bits"
 @require num_bits > 0   : "Number of bits must be at least 1"
 @require num_bits <= 32 : "Number of bits can not be larger than 32"
*>
fn void DynamicBitList.push(&self, uint b, usz num_bits, bool lsb = true)
{
	isz start, end;
	start = 0;
	end   = num_bits - 1;
	if (lsb)
	{
		for (isz i = start; i <= end; i+= lsb ? 1 : -1)
		{
			self.push_bit(get_bit_state(b, i));
		}
	}
	else
	{
		for (isz i = end; i >= start; i--)
		{
			self.push_bit(get_bit_state(b, i));
		}
	}
}

fn void main()
{
	// test_huff_tree();
	test_package_merge();
	// no_compression();
	// fixed_huff();
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
	char[1024] input;
	foreach (i, &e : input) *e = (char)(i % 255);
	char[] encoded = nocomp_encode(input[..], tmem);
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
	bs.push((char)len, 8, lsb: true);
	bs.push((char)(len>>8), 8, lsb: true);

	ushort nlen = ~len;
	bs.push((char)nlen, 8, lsb: true);
	bs.push((char)(nlen>>8), 8, lsb: true);

	// Encode data
	foreach(c: input)
	{
		bs.push(c, 8, lsb: true);
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

	// Fixed Huffman codes bit_len
	int[*] bit_len = {
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	};

	// Generate the fixed Huffman codes
	uint[] huff_codes = gen_huff(bit_len[..]);

	// Distance codes bit_len
	int[*] dist_len = {
		[0] = 1,
	};

	// Generate the distance codes
	uint[] dist_codes = gen_huff(dist_len[..]);

	// Input string to be deflated
	char[] s = "hello world";

	// Encode string
	char[] encoded = dynamic_huff_encode(s,
			huff_codes[:257], bit_len[:257],
			dist_codes, dist_len[..],
		tmem);

	verify(encoded, s, "dynamic_huff");
}

fn char[] dynamic_huff_encode(char[] input, uint[] codes, int[] len,
					uint[]dist_codes, int[] dist_len,
			Allocator allocator) => @pool()
{

	// FIXME: this is faulty.
	// We need to create a proper codegen from the literal and distance
	// lengths

	// Create Huff codegen
	uint[] hc_order = {
		16, 17, 18,  0,  8,
		 7,  9,  6, 10,  5,
		11,  4, 12,  3, 13,
	 	 2, 14,  1, 15,
	 };

	uint[] hc_order_lookup = {
	   	 3, 17, 15, 13, 11,
		 9,  7,  5,  4,  6,
		 8, 10, 12, 14, 16,
	        18,  0,  1, 2
	};

	int hc_bit_len = 7;
	int[*] hc_len = { [0..18] = 0 };

	foreach (l: len) hc_len[hc_order_lookup[l]] = hc_bit_len;
	foreach (l: dist_len) hc_len[hc_order_lookup[l]] = hc_bit_len;

	uint[] hc_codes = gen_huff(hc_len[..]);
	foreach (i, code : hc_codes)
	{
	io::printfn("hc_codes %d %08b ", hc_order[i], hc_codes[i]);
	}

	DynamicBitList bs;
	bs.tinit();

	// Set Block header
	// Push BFINAL (0b1) and BTYPE (0b10) as 0x101 [read from right to left]
	bs.push(0b101, 3);

	// Push 5 bits HLIT (# of literal/length codes - 257)
	bs.push(codes.len-257, 5, true);

	// Push 5 bits HDIST (# of distance codes - 1)
	bs.push(dist_codes.len-1, 5, true);

	// Push 4 bits HCLEN (# of code length codes - 4)
	bs.push(hc_codes.len-4, 4, true);

	// Assume for now that we use all 19 codes with a code bit length of 3
	// bits
	for (usz i = 0; i < 19; i++)
	{
		io::printfn("having: %d -> %d -> %d", i, hc_order[i], hc_len[i]);
		bs.push(hc_len[i], 3, true);
	}

	// Now save the literal/length tree, hc-encoded
	foreach(l: len)
	{
		usz index = hc_order_lookup[l];
		bs.push(hc_codes[index], hc_len[index], false);
	}

	// Now save the distance/tree, hc-encoded
	foreach(l: dist_len)
	{
		usz index = hc_order_lookup[l];
		bs.push(hc_codes[index], hc_len[index], false);
	}

	// And finally the compressed data
	foreach(c: input)
	{
		bs.push(codes[c], len[c], false);
	}

	// Add end of block code 256
	bs.push(codes[256], len[256], false);

	foreach (i, b : bs.list)
	{
		io::printfn("bytes %2d: 0x%02x 0b%08b", i, b, b);
	}

	return bs.list.to_array(allocator);
}

<*
 TODO: Entire LZ (length/distance) pairs part is currently not implemented.
*>
fn void fixed_huff() => @pool()
{
	io::printn("-- fixed huffman encoding --");

	// Fixed Huffman codes bit_len
	int[*] bit_len = {
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	};

	// Generate the fixed Huffman codes
	uint[] huff_codes = gen_huff(bit_len[..]);

	// Distance codes dist_len
	int[*] dist_len = {
		[  0..32] = 5,
	};

	// Generate the distance codes
	uint[] dist_codes = gen_huff(dist_len[..]);

	// Input string to be deflated
	char[] s = "hello world";

	// Encode string
	char[] encoded = fixed_huff_encode(s, huff_codes, bit_len[..], tmem);

	verify(encoded, s, "fixed_huff");
}

fn void verify(char[] encoded, char[] input, String test_name)
{
	// Decompress with inflate
	char[1024] output;
	inflate::uncompress(output[..], encoded)!!;
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
fn char[] fixed_huff_encode(char[] input, uint[] codes, int[] len, Allocator allocator) => @pool()
{
	DynamicBitList bs;
	bs.tinit();

	// Set Block header
	// Push BFINAL (0b1) and BTYPE (0b01) as 0x011 [read from right to left]
	bs.push(0b011, 3);

	foreach(c: input)
	{
		bs.push(codes[c], len[c], false);
	}

	// Add end of block code 256
	bs.push(codes[256], len[256], false);

	foreach (i, b : bs.list)
	{
		io::printfn("bytes %2d: 0x%02x 0b%08b", i, b, b);
	}

	return bs.list.to_array(allocator);
}

<*
 RFC 1951, Section 3.2.2. Use of Huffman coding in the "deflate" format
 require bit_len.len == 288 || bit_len.len == 19: "Code bit_len array must contain exactly 288 or 19 elements"

 @param bit_len : "Array with bit bit_len of Huffman codes"
 @return "Huffman codes"
*>
fn uint[] gen_huff(int[] bit_len)
{
	// Toy model in RFC:
	// int[*] bit_len = { 3, 3, 3, 3, 3, 2, 4, 4 };
	// char[*] sym = "ABCDEFGH";

        // 1)  Count the number of codes for each code length.  Let
        //     bl_count[N] be the number of codes of length N, N >= 1.

	HashMap{int, int} bl_count;
	bl_count.tinit();
	foreach (len: bit_len) bl_count[len] += 1;
	// io::printfn("bl_count[N]: %s", bl_count);

        // 2)  Find the numerical value of the smallest code for each
        //     code length:

	const MAX_BITS = 32; // ??

	List{int} next_code;
	next_code.tinit();
	next_code.push(0); // Move index to 1

	int code = 0;
	bl_count[0] = 0;
	for (int bits = 1; bits <= MAX_BITS; bits++)
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

	uint[] codes = mem::temp_array(uint, bit_len.len);
	foreach (i, len: bit_len)
	{
		if (len == 0) continue;
		// io::printfn("%4d\t%d\t%0*b", i, len, len, next_code[len]);
		codes[i] = next_code[len];
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
	uint[] freqs = {4,4,4,3,2,1};
	uint[] bl_count = huff_bit_counts(freqs, 5);
	io::printfn("bl_count: %s", bl_count);

	const MAX_BITS = 32; // ??

	List{int} next_code;
	next_code.tinit();
	next_code.push(0); // Move index to 1

	int code = 0;
	for (int bits = 1; bits <= bl_count.len; bits++)
	{
	        code = (code + bl_count[bits-1]) << 1;
	        next_code.push(code);
	}

	uint[] codes = mem::temp_array(uint, freqs.len);
	usz code_pos = 0;
	foreach (len, counts : bl_count)
	{
		if (len == 0) continue;
		while (counts--)
		{
			codes[code_pos++] = next_code[len];
			next_code[len]++;
		}
	}

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
	Node *left;
	Node *right;
}

fn bool Node.less(&self, Node* b) => self.freq < b.freq;

fn Node* make_node(NodeType type, uint freq = char.max, Allocator allocator = tmem)
{
	return allocator::new(allocator, Node, { type, freq, null, null });
}

// Create a huffman tree from a set of frequencies.  Ensure that the huffman
// codes are not longer than max_bits (adding max-bits - 1 dummy nodes).
// Returning the bit lengths for the huffman codes.
<*
 @require max_bits < 16
*>
fn uint[] huff_bit_counts(uint[] freqs, uint max_bits)
{
	usz n = freqs.len + max_bits - 1;
	// HuffHeap heap = { mem::temp_array(Node*, n), 0, n };

	PriorityQueue{Node*} heap;
	heap.tinit();

	// Fill heap with freqs
	foreach (freq : freqs)
	{
		heap.push(make_node(NodeType.LEAF, freq));
	}
	// Add max_bits - 1 dummy nodes
	for (usz i = 0; i < max_bits - 1; i++)
	{
		heap.push(make_node(NodeType.DUMMY));
	}

	// heap.display();

	while (heap.len() != 1)
	{
		Node *a = heap.pop()!!;
		Node *b = heap.pop()!!;
		uint new_freq = a.freq + b.freq;
		Node *new_node = make_node(NodeType.INTERNAL, new_freq);
		io::printfn("combine %d + %d = %d", a.freq, b.freq, new_freq);
		new_node.left = a;
		new_node.right = b;
		heap.push(new_node);
		// heap.display();
	}

	// heap.first() contains now root node
	// uint[] counts = mem::temp_array(uint, (usz)(max_bits+1));
	uint[] counts = mem::temp_array(uint, max_bits);
	dfs_traverse(heap.first()!!, counts, -(max_bits-2));
	// dfs_traverse(heap.first()!!, counts, 0);
	return counts;
}

fn void dfs_traverse(Node *n, uint[] counts, uint depth)
{
	if (n.type == LEAF)
	{
		io::printfn("depth = %d [freq:%d]", depth, n.freq);
		counts[depth] += 1;
		return;
	}

	// Recurse through dummies and internal
	if (n.left != null) dfs_traverse(n.left, counts, depth+1);
	if (n.right != null) dfs_traverse(n.right, counts, depth+1);
}

struct HuffHeap
{
	Node*[] heap;
	usz size;
	usz capacity;
}

fn void HuffHeap.display(&self)
{
	for (usz i = 0; i < self.size; i++)
	{
		io::printf("(%d)", self.heap[i].freq);
	}
	io::printn("");
}

fn usz HuffHeap.len(&self) => self.size;

fn Node*? HuffHeap.first(&self)
{
	return self.heap[0];
}

fn void HuffHeap.push(&self, Node* node)
{
	assert(self.size < self.capacity);

	self.heap[self.size] = node;
	usz i = self.size;
	self.size++;

	// Heapify up
	usz parent;
	while (i > 0)
	{
		parent = (i - 1 ) / 2;
 		if (self.heap[parent].freq < self.heap[i].freq) break;

		@swap(self.heap[i], self.heap[parent]);
		i = parent;
	}
}

fn Node*? HuffHeap.pop(&self)
{
	usz i = 0;
	Node* top = self.heap[i];

	// Replace with last element
	self.heap[i] = self.heap[self.size - 1];
	self.size--;

	// Heapify down
	while (1)
	{
		usz left = 2 * i + 1;
		usz right = 2 * i + 2;
		usz smallest = i;

		if (left < self.size && self.heap[left].freq < self.heap[smallest].freq)
		{
			smallest = left;
		}
		if (right < self.size && self.heap[right].freq < self.heap[smallest].freq)
		{
			smallest = right;
		}

		if (smallest == i) break;

		@swap(self.heap[i], self.heap[smallest]);
		i = smallest;
	}
	return top;
}

fn void test_package_merge()
{
	uint[] freqs = {4,4,4,0,3,2,1};
	uint[] counts = package_merge(freqs, 5, tmem);
	assert(freqs.len == counts.len);
	io::printfn("counts: %s", counts);

	uint[] codes = gen_huff(counts);
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
fn uint[] package_merge(uint[] freqs, uint max_bits, Allocator allocator) => @pool()
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
	io::printfn("before: %s", mappings);
	sort::quicksort(mappings.array_view());
	io::printfn("after:  %s", mappings);

	uint[] hist = mem::temp_array(uint, num_codes);
	foreach (i, m: mappings) hist[i] = m.freq;

	// One or two codes are encoded with a single bit
	if (num_codes <= 2)
	{
		hist[..] = 0;
		hist[0] = 1;
		return hist;
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
	uint[] code_length = allocator::new_array(allocator, uint, freqs.len);
	foreach (i, m: mappings)
	{
		code_length[m.index] = hist[i];
	}

	return code_length;
}

fn void test_package_merge_fn() @test => @pool()
{
	uint[] freqs = {4,4,4,0,3,2,1};
	uint[] counts = package_merge(freqs, 5, tmem);
	assert(freqs.len == counts.len);
	assert(counts == {2,2,2,0,3,4,4});
}

