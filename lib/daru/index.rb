module Daru
  class Index
    include Enumerable
    # It so happens that over riding the .new method in a super class also
    # tampers with the default .new method for class that inherit from the
    # super class (Index in this case). Thus we first alias the original 
    # new method (from Object) to __new__ when the Index class is evaluated, 
    # and then we use an inherited hook such that the old new method (from
    # Object) is once again the default .new for the subclass.
    # Refer http://blog.sidu.in/2007/12/rubys-new-as-factory.html
    class << self
      alias :__new__ :new
      
      def inherited subclass
        class << subclass
          alias :new :__new__
        end
      end
    end

    # We over-ride the .new method so that any sort of Index can be generated
    # from Daru::Index based on the types of arguments supplied.
    def self.new *args, &block
      source = args[0]

      idx =
      if source and source[0].is_a?(Array)
        Daru::MultiIndex.from_tuples source
      elsif source and source.is_a?(Array) and !source.empty? and 
        source.all? { |e| e.is_a?(DateTime) }
        Daru::DateTimeIndex.new(source, freq: :infer)
      else
        i = self.allocate
        i.send :initialize, *args, &block
        i
      end

      idx
    end

    def each(&block)
      @relation_hash.each_key(&block)
      self
    end

    def map(&block)
      to_a.map(&block)
    end

    attr_reader :relation_hash, :size

    def initialize index
      index = 0                         if index.nil?
      index = Array.new(index) { |i| i} if index.is_a? Integer
      index = index.to_a                if index.is_a? Daru::Index

      @relation_hash = {}
      index.each_with_index do |n, idx|
        @relation_hash[n] = idx 
      end

      @relation_hash.freeze
      @keys = @relation_hash.keys
      @size = @relation_hash.size
    end

    def ==(other)
      return false if self.class != other.class or other.size != @size

      @relation_hash.keys   == other.to_a and 
      @relation_hash.values == other.relation_hash.values
    end

    def [](*key)
      loc = key[0]

      case 
      when loc.is_a?(Range)
        first = loc.first
        last = loc.last

        slice first, last
      when key.size > 1
        if include? key[0]
          Daru::Index.new key.map { |k| k }
        else
          # Assume the user is specifing values for index not keys
          # Return index object having keys corresponding to values provided
          Daru::Index.new key.map { |k| key k }
        end
      else
        v = @relation_hash[loc]
        if !v
          return loc if loc.is_a? Numeric and loc < size
          raise IndexError, "Specified index #{loc.inspect} does not exist"
        end
        v
      end
    end

    def slice *args
      start   = args[0]
      en      = args[1]
      indexes = []

      if start.is_a?(Integer) and en.is_a?(Integer)
        Index.new @keys[start..en]
      else
        start_idx = @relation_hash[start]
        en_idx    = @relation_hash[en]

        Index.new @keys[start_idx..en_idx]
      end
    end

    # Produce new index from the set union of two indexes.
    def |(other)
      Index.new(to_a | other.to_a)
    end

    # Produce a new index from the set intersection of two indexes
    def & other
      
    end

    def to_a
      @relation_hash.keys
    end

    def key(value)
      @relation_hash.keys[value]
    end

    def include? index
      @relation_hash.has_key? index
    end

    def empty?
      @relation_hash.empty?
    end

    def dup
      Daru::Index.new @relation_hash.keys
    end

    def _dump depth
      Marshal.dump({relation_hash: @relation_hash})
    end

    def self._load data
      h = Marshal.load data

      Daru::Index.new(h[:relation_hash].keys)
    end

    # Provide an Index for sub vector produced
    #
    # @param input_indexes [Array] the input by user to index the vector
    # @return [Object] the Index object for sub vector produced
    def conform input_indexes
      self
    end
  end # class Index

  class MultiIndex < Index
    include Enumerable

    def each(&block)
      to_a.each(&block)  
    end

    def map(&block)
      to_a.map(&block)
    end

    attr_reader :labels

    def levels
      @levels.map { |e| e.keys }
    end

    def initialize opts={}
      labels = opts[:labels]
      levels = opts[:levels]

      raise ArgumentError, 
        "Must specify both labels and levels" unless labels and levels
      raise ArgumentError,
        "Labels and levels should be same size" if labels.size != levels.size
      raise ArgumentError,
        "Incorrect labels and levels" if incorrect_fields?(labels, levels)

      @labels = labels
      @levels = levels.map { |e| Hash[e.map.with_index.to_a]}
    end

    def incorrect_fields? labels, levels
      max_level = levels[0].size

      correct = labels.all? { |e| e.size == max_level }
      correct = levels.all? { |e| e.uniq.size == e.size }

      !correct
    end

    private :incorrect_fields?

    def self.from_arrays arrays
      levels = arrays.map { |e| e.uniq.sort_by { |a| a.to_s  } }
      labels = []

      arrays.each_with_index do |arry, level_index|
        label = []
        level = levels[level_index]
        arry.each do |lvl|
          label << level.index(lvl)
        end

        labels << label
      end

      MultiIndex.new labels: labels, levels: levels
    end

    def self.from_tuples tuples
      from_arrays tuples.transpose
    end

    def [] *key
      key.flatten!
      case
      when key[0].is_a?(Range) then retrieve_from_range(key[0])
      when (key[0].is_a?(Integer) and key.size == 1) then try_retrieve_from_integer(key[0])
      else
        begin
          retrieve_from_tuples key
        rescue NoMethodError
          raise IndexError, "Specified index #{key.inspect} do not exist"
        end
      end
    end

    def try_retrieve_from_integer int
      return retrieve_from_tuples([int]) if @levels[0].has_key?(int)
      int
    end

    def retrieve_from_range range
      MultiIndex.from_tuples(range.map { |index| key(index) })
    end

    def retrieve_from_tuples key
      chosen = []

      key.each_with_index do |k, depth|
        level_index = @levels[depth][k]
        label = @labels[depth]
        chosen = find_all_indexes label, level_index, chosen
      end

      return chosen[0] if chosen.size == 1 and key.size == @levels.size
      return multi_index_from_multiple_selections(chosen)              
    end

    def multi_index_from_multiple_selections chosen
      MultiIndex.from_tuples(chosen.map { |e| key(e) })
    end

    def find_all_indexes label, level_index, chosen
      if chosen.empty?
        label.each_with_index do |lbl, i|
          if lbl == level_index then chosen << i end
        end
      else
        chosen.keep_if { |c| label[c] == level_index }
      end

      chosen
    end

    private :find_all_indexes, :multi_index_from_multiple_selections,
      :retrieve_from_range, :retrieve_from_tuples

    def key index
      raise ArgumentError,
        "Key #{index} is too large" if index >= @labels[0].size

      level_indexes = 
      @labels.inject([]) do |memo, label|
        memo << label[index]
        memo
      end

      tuple = []
      level_indexes.each_with_index do |level_index, i|
        tuple << @levels[i].keys[level_index]
      end

      tuple
    end

    def dup
      MultiIndex.new levels: levels.dup, labels: labels
    end

    def drop_left_level by=1
      MultiIndex.from_arrays to_a.transpose[by..-1]
    end

    def | other
      MultiIndex.from_tuples(to_a | other.to_a)
    end

    def & other
      MultiIndex.from_tuples(to_a & other.to_a)
    end

    def empty?
      @labels.flatten.empty? and @levels.all? { |l| l.empty? }
    end

    def include? tuple
      tuple.flatten!
      tuple.each_with_index do |tup, i|
        return false unless @levels[i][tup]
      end
      true
    end

    def size
      @labels[0].size
    end

    def width
      @levels.size
    end

    def == other
      self.class == other.class  and 
      labels     == other.labels and 
      levels     == other.levels 
    end

    def to_a
      (0...size).map { |e| key(e) }
    end

    def values
      Array.new(size) { |i| i }
    end

    def inspect
      "Daru::MultiIndex:#{self.object_id} (levels: #{levels}\nlabels: #{labels})"
    end

    # Provide a MultiIndex for sub vector produced
    #
    # @param input_indexes [Array] the input by user to index the vector
    # @return [Object] the MultiIndex object for sub vector produced
    def conform input_indexes
      return self if input_indexes[0].is_a? Range
      drop_left_level input_indexes.size
    end
  end
end