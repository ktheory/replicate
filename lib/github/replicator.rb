module GitHub
  module Replicator
    # Dump replicants in a streaming fashion.
    #
    # The Dumper takes an ActiveRecord object and generates one or more replicant
    # objects. A replicant object has the form: [type, id, attributes] and
    # describes exactly one record in the database. The type and id identify the
    # record's model class name string and primary key id, respectively. The
    # attributes is a Hash of primitive typed objects generated by a call to
    # ActiveRecord::Base#attributes.
    #
    # Dumping to an array:
    #
    #     >> replicator = Replicator::Dumper.new
    #     >> replicator.dump_repository User / :defunkt / :github
    #     >> pp replicator.to_a
    #
    # Dumping to stdout in marshal format:
    #
    #     >> writer = lambda { |*a| Marshal.dump(a, $stdout) }
    #     >> replicator = Replicator::Dumper.new(&writer)
    #     >> replicator.dump_repository User / :defunkt / :github
    #
    class Dumper
      # Create a new Dumper.
      #
      # io     - IO object to write marshalled replicant objects to. When
      #          not given, objects are written to an array available at #to_a.
      # write  - Block called when an object needs to be written. Use this for
      #          complete control over how objects are serialized.
      def initialize(io=nil, &write)
        write ||= lambda { |*replicant| @objects << replicant }
        write ||= lambda { |*replicant| Marshal.dump(replicant, io) } if io
        @objects = []
        @write = write
        @memo = {}
      end

      # Grab dumped objects array. Always empty when a custom write function was
      # provided when initialized.
      def to_a
        @objects
      end

      # Check if object has been dumped yet.
      def dumped?(object)
        @memo["#{object.class}:#{object.id}"]
      end

      # Call the write method given in the initializer or write to the internal
      # objects array when no write method was given.
      #
      # type       - The model class name as a String.
      # id         - The record's id. Usually an integer.
      # attributes - All model attributes.
      #
      # Returns nothing.
      def write(type, id, attributes)
        @write.call(type, id, attributes)
      end

      # Dump one or more objects to the internal array or provided dump
      # stream. This method guarantees that the same object will not be dumped
      # more than once.
      #
      # objects - ActiveRecord object instances.
      #
      # Returns nothing.
      def dump(*objects)
        objects = objects[0] if objects.size == 1 && objects[0].respond_to?(:to_ary)
        objects.each do |object|
          next if object.nil?
          next if dumped?(object)

          meth = "dump_#{object.class.to_s.underscore}"
          if respond_to?(meth)
            send meth, object
          else
            dump_active_record_object object
          end
        end
      end

      # Low level dump method. Generates a call to write with the attributes of
      # the given objects. This method is used in dumpspecs when dumping the
      # dumpspec's subject.
      def dump_object(object)
        return if dumped?(object)
        @memo["#{object.class}:#{object.id}"] = object
        write object.class.name, object.id, object.attributes
      end

      # Dump all objects the given object depends on via belongs_to association,
      # then dump the object itself.
      #
      # object - An ActiveRecord object instance.
      #
      # Returns nothing.
      def dump_active_record_object(object)
        dump_associated_objects object, :belongs_to
        dump_object object
        dump_associated_objects object, :has_one
      end

      # Dump all object associations of a given type.
      #
      # object - AR object instance.
      # association_type - :has_one, :belongs_to, :has_many
      #
      # Returns nothing.
      def dump_associated_objects(object, association_type)
        model = object.class
        model.reflect_on_all_associations(association_type).each do |reflection|
          dependent = object.send reflection.name
          case dependent
          when ActiveRecord::Base, Array
            dump dependent
          when nil
            next
          else
            warn "warn: #{model}##{reflection.name} #{association_type} association " \
                 "unexpectedly returned a #{dependent.class}. skipping."
          end
        end
      end

      ##
      # Dumpspecs

      def dump_repository(repository)
        dump_active_record_object repository
        dump repository.commit_comments
        dump repository.languages
        dump repository.issues
        dump repository.downloads
      end

      def dump_user(user)
        dump_active_record_object user
        dump user.emails
      end

      def dump_issue(issue)
        dump_active_record_object issue
        dump issue.labels
        dump issue.events
        dump issue.comments
      end

      def dump_pull_request(pull)
        dump_active_record_object pull
        dump pull.review_comments
      end
    end

    # Load replicants in a streaming fashion.
    #
    # The Loader reads [type, id, attributes] replicant tuples and creates
    # objects in the current environment.
    #
    # Objects are expected to arrive in order such that a record referenced via
    # foreign key always precedes the referencing record. The Loader maintains a
    # mapping of primary keys from the dump system to the current environment.
    # This mapping is used to properly establish new foreign key values on all
    # records inserted.
    class Loader
      def initialize
        fail "not ready for production" if RAILS_ENV == 'production'
        @keymap = {}
        @warned = {}
        @foreign_key_map = {}
      end

      # Read replicant tuples from the given IO object and load into the
      # database within a single transaction.
      def read(io)
        ActiveRecord::Base.transaction do
          while object = Marshal.load(io)
            type, id, attrs = object
            record = load(type, id, attrs)
            yield record if block_given?
          end
        end
      rescue EOFError
      end

      # Load an individual record into the database.
      #
      # type  - Model class name as a String.
      # id    - Primary key id of the record on the dump system. This must be
      #         translated to the local system and stored in the keymap.
      # attrs - Hash of attributes to set on the new record.
      #
      # Returns the ActiveRecord object instance for the new record.
      def load(type, id, attributes)
        model = Object::const_get(type)
        instance = load_object model, attributes
        primary_key = nil
        foreign_key_map = model_foreign_key_map(model)

        # write each attribute separately, converting foreign key values to
        # their local system values.
        attributes.each do |key, value|
          if key == model.primary_key
            primary_key = value
            next
          elsif value.nil?
            instance.write_attribute key, value
          elsif dependent_model = foreign_key_map[key]
            if record = find_dependent_object(dependent_model, value)
              instance.write_attribute key, record.id
            else
              warn "warn: #{model} referencing #{dependent_model}[#{value}] " \
                   "not found in keymap"
            end
          elsif key =~ /^(.*)_id$/
            if !@warned["#{model}:#{key}"]
              warn "warn: #{model}.#{key} looks like a foreign key but has no association."
              @warned["#{model}:#{key}"] = true
            end
            instance.write_attribute key, value
          else
            instance.write_attribute key, value
          end
        end

        # write to the database without validations and callbacks, register in
        # the keymap and return the AR object
        instance.save false
        register_dependent_object instance, primary_key
        instance
      end

      # Load a mapping of foreign key column names to association model classes.
      #
      # model - The AR class.
      #
      # Returns a Hash of { foreign_key => model_class } items.
      def model_foreign_key_map(model)
        @foreign_key_map[model] ||=
          begin
            map = {}
            model.reflect_on_all_associations(:belongs_to).each do |reflection|
              foreign_key = reflection.options[:foreign_key] || "#{reflection.name}_id"
              map[foreign_key.to_s] = reflection.klass
            end
            map
          end
      end

      # Find the local AR object instance for the given model class and dump
      # system primary key.
      #
      # model - An ActiveRecord subclass.
      # id    - The dump system primary key id.
      #
      # Returns the AR object instance if found, nil otherwise.
      def find_dependent_object(model, id)
        @keymap["#{model}:#{id}"]
      end

      # Register a newly created or updated AR object in the keymap.
      #
      # object - An ActiveRecord object instance.
      # id     - The dump system primary key id.
      #
      # Returns object.
      def register_dependent_object(object, id)
        model = object.class
        while model != ActiveRecord::Base && model != Object
          @keymap["#{model}:#{id}"] = object
          model = model.superclass
        end
        object
      end

      # Load an AR instance from the current environment.
      #
      # model - The ActiveRecord class to search for.
      # attrs - Hash of dumped record attributes.
      #
      # Returns an instance of model. This is usually a new record instance but
      # can be overridden to return an existing record instead.
      def load_object(model, attributes)
        meth = "load_#{model.to_s.underscore}"
        instance =
          if respond_to?(meth)
            send(meth, attributes) || model.new
          else
            model.new
          end
        def instance.callback(*args);end # Rails 2.x hack to disable callbacks.
        instance
      end

      ##
      # Loadspecs

      # Use existing users when the login is available.
      def load_user(attrs)
        User.find_by_login(attrs['login'])
      end

      # Delete existing repositories and create new ones. Nice because we don't
      # have to worry about updating existing issues, comments, etc.
      def load_repository(attrs)
        owner = find_dependent_object(User, attrs['owner_id'])
        if repo = Repository.find_by_name_with_owner("#{owner.login}/#{attrs['name']}")
          warn "warn: deleting existing repository: #{repo.name_with_owner} (#{repo.id})"
          repo.destroy
        end
        Repository.new
      end

      def load_language_name(attrs)
        LanguageName.find_by_name(attrs['name'])
      end
    end
  end
end