module CalibreHub
  module Tui
    # The library's books, loaded a page at a time where the screen is (like
    # an infinite scroll that can also jump: G loads the last page, not all
    # pages before it). Answers of an older query are dropped by generation.
    class Rows
      getter page_size : Int32
      # nil until the first page arrived
      getter total : Int32? = nil
      getter generation = 0
      @pages = {} of Int32 => Array(Book)
      @loading = Set(Int32).new

      def initialize(@page_size = PAGE_SIZE)
      end

      def reset : Nil
        @generation += 1
        @pages.clear
        @loading.clear
        @total = nil
      end

      # rows known so far: the total once known
      def size : Int32
        @total || 0
      end

      def loaded? : Bool
        !@total.nil?
      end

      def loading? : Bool
        !@loading.empty?
      end

      def [](index : Int32) : Book?
        @pages[index // @page_size]?.try(&.[index % @page_size]?)
      end

      # Pages needed for rows from..to that are neither loaded nor loading;
      # they count as loading from now on. Before the total is known only the
      # first page is asked for.
      def wanted(from : Int32, to : Int32) : Array(Int32)
        last = @total.try { |t| t <= 0 ? -1 : (t - 1) // @page_size }
        first_page = Math.max(0, from) // @page_size
        last_page = Math.max(0, to) // @page_size
        if last
          last_page = Math.min(last_page, last)
        else
          first_page = last_page = 0
        end
        acc = (first_page..last_page).reject { |p| @pages.has_key?(p) || @loading.includes?(p) }.to_a
        acc.each { |p| @loading << p }
        acc
      end

      # A page arrived; false if it belongs to an older query
      def store(generation : Int32, page : Int32, total : Int32, books : Array(Book)) : Bool
        return false unless generation == @generation
        @loading.delete(page)
        @total = total
        @pages[page] = books
        true
      end

      def failed(generation : Int32, page : Int32) : Nil
        @loading.delete(page) if generation == @generation
      end

      # A changed book in place of the loaded one (same id); false if it
      # isn't loaded
      def replace(book : Book) : Bool
        @pages.each_value do |books|
          books.each_with_index do |b, i|
            next unless b.id == book.id
            books[i] = book
            return true
          end
        end
        false
      end

      # all loaded books
      def loaded_books : Array(Book)
        @pages.values.flatten
      end

      # index of a book among the loaded rows
      def index_of(id : Int64) : Int32?
        @pages.each do |p, books|
          books.each_with_index { |b, i| return p * @page_size + i if b.id == id }
        end
        nil
      end
    end
  end
end
