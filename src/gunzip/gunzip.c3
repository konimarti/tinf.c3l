import std::io;

import tinf::gzip;

fn void main() => @pool()
{
	ByteWriter writer;
	io::copy_to(io::stdin(), writer.tinit())!!;

	String src = writer.str_view();

	usz dlen = gzip::uncompressed_len(src);
	char[] dst = mem::talloc_array(char, dlen);

	gzip::uncompress(dst, src)!!;

	io::print((String)dst);
}
