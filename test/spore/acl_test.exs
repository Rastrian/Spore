defmodule Spore.ACLTest do
  use ExUnit.Case, async: false

  alias Spore.ACL

  setup do
    on_exit(fn ->
      Application.delete_env(:spore, :allow)
      Application.delete_env(:spore, :deny)
    end)

    :ok
  end

  describe "parse_list/1" do
    test "parses single IPs and CIDR entries" do
      assert ACL.parse_list("1.2.3.4,10.0.0.0/8") == [
               {:ip, {1, 2, 3, 4}},
               {:cidr, {10, 0, 0, 0}, 8}
             ]
    end

    test "splits on comma, space and newline" do
      expected = [{:ip, {1, 2, 3, 4}}, {:cidr, {10, 0, 0, 0}, 8}]

      assert ACL.parse_list("1.2.3.4 10.0.0.0/8") == expected
      assert ACL.parse_list("1.2.3.4\n10.0.0.0/8") == expected
      assert ACL.parse_list("1.2.3.4,\n 10.0.0.0/8") == expected
    end

    test "parses IPv6 addresses as plain ip entries" do
      assert ACL.parse_list("::1") == [{:ip, {0, 0, 0, 0, 0, 0, 0, 1}}]
    end

    test "invalid entries are silently dropped" do
      assert ACL.parse_list("999.1.1.1") == []
      assert ACL.parse_list("10.0.0.0/x") == []
      assert ACL.parse_list("10.0.0.0/8x") == []
      assert ACL.parse_list("abc") == []

      assert ACL.parse_list("1.2.3.4,abc,10.0.0.0/8") == [
               {:ip, {1, 2, 3, 4}},
               {:cidr, {10, 0, 0, 0}, 8}
             ]
    end

    test "empty and blank strings parse to an empty list" do
      assert ACL.parse_list("") == []
      assert ACL.parse_list("   ") == []
    end
  end

  describe "allow?/1" do
    test "with empty allow and deny lists everything is allowed" do
      assert ACL.allow?({8, 8, 8, 8})
      assert ACL.allow?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "an IP present in a nonempty allow list is allowed" do
      Application.put_env(:spore, :allow, ACL.parse_list("1.2.3.4"))

      assert ACL.allow?({1, 2, 3, 4})
      refute ACL.allow?({5, 6, 7, 8})
    end

    test "explicit deny wins over allow" do
      Application.put_env(:spore, :allow, ACL.parse_list("10.0.0.0/8"))
      Application.put_env(:spore, :deny, ACL.parse_list("10.1.2.3"))

      assert ACL.allow?({10, 9, 9, 9})
      refute ACL.allow?({10, 1, 2, 3})
    end

    test "deny alone blocks only the denied IP" do
      Application.put_env(:spore, :deny, ACL.parse_list("1.2.3.4"))

      refute ACL.allow?({1, 2, 3, 4})
      assert ACL.allow?({9, 9, 9, 9})
    end

    test "CIDR /8 boundaries" do
      Application.put_env(:spore, :allow, ACL.parse_list("10.0.0.0/8"))

      assert ACL.allow?({10, 0, 0, 0})
      assert ACL.allow?({10, 0, 0, 1})
      assert ACL.allow?({10, 255, 255, 255})
      refute ACL.allow?({11, 0, 0, 1})
      refute ACL.allow?({9, 255, 255, 255})
    end

    test "CIDR /32 requires an exact match" do
      Application.put_env(:spore, :allow, ACL.parse_list("1.2.3.4/32"))

      assert ACL.allow?({1, 2, 3, 4})
      refute ACL.allow?({1, 2, 3, 5})
    end

    test "CIDR /0 matches any IPv4 address" do
      Application.put_env(:spore, :allow, ACL.parse_list("0.0.0.0/0"))

      assert ACL.allow?({1, 2, 3, 4})
      assert ACL.allow?({203, 0, 113, 7})
    end

    test "an IPv6 tuple never matches IPv4 rules and does not crash" do
      Application.put_env(:spore, :allow, ACL.parse_list("10.0.0.0/8,1.2.3.4"))
      Application.put_env(:spore, :deny, ACL.parse_list("10.0.0.0/8"))

      refute ACL.allow?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 exact-ip entries match by equality" do
      Application.put_env(:spore, :allow, ACL.parse_list("::1"))

      assert ACL.allow?({0, 0, 0, 0, 0, 0, 0, 1})
      refute ACL.allow?({0, 0, 0, 0, 0, 0, 0, 2})
    end

    test "IPv6 CIDR rules match correctly" do
      Application.put_env(:spore, :allow, ACL.parse_list("2001:db8::/32"))

      assert ACL.allow?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      refute ACL.allow?({0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 CIDR /128 and /0 boundaries" do
      Application.put_env(:spore, :allow, ACL.parse_list("2001:db8::1/128"))
      assert ACL.allow?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      refute ACL.allow?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 2})

      Application.put_env(:spore, :allow, ACL.parse_list("::/0"))
      assert ACL.allow?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 deny rule blocks the matching client" do
      Application.put_env(:spore, :allow, [])
      Application.put_env(:spore, :deny, ACL.parse_list("2001:db8:dead::/48"))

      refute ACL.allow?({0x2001, 0xDB8, 0xDEAD, 0, 0, 0, 0, 1})
      assert ACL.allow?({0x2001, 0xDB8, 0xDEAD + 1, 0, 0, 0, 0, 1})
    end

    test "IPv4-mapped IPv6 clients match IPv4 rules" do
      Application.put_env(:spore, :allow, ACL.parse_list("10.0.0.0/8"))

      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}
      assert ACL.allow?(mapped)
      refute ACL.allow?({0, 0, 0, 0, 0, 0xFFFF, 0x0B00, 0x0001})
    end

    test "IPv6 CIDR written over a v4-mapped address matches both spellings" do
      Application.put_env(:spore, :allow, ACL.parse_list("::ffff:10.0.0.0/104"))

      assert ACL.allow?({10, 0, 0, 1})
      assert ACL.allow?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0002})
      refute ACL.allow?({11, 0, 0, 1})
    end

    test "IPv6 CIDR with an invalid prefix length is dropped at parse time" do
      assert ACL.parse_list("2001:db8::/129") == []
      assert ACL.parse_list("2001:db8::/-1") == []
      assert ACL.parse_list("1.2.3.4/33") == []
      assert ACL.parse_list("1.2.3.4/-1") == []
    end

    test "a real IPv6 client never matches an IPv4 CIDR rule" do
      Application.put_env(:spore, :allow, ACL.parse_list("10.0.0.0/8"))

      refute ACL.allow?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end
  end
end
