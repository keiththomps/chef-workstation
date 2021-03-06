#
# Copyright:: Copyright (c) 2018 Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module ChefCLI

  # CommandsMap maintains a mapping of subcommand names to the files where
  # those commands are defined and the classes that implement the commands.
  #
  # In ruby it's more typical to handle this sort of thing using conventions
  # and metaprogramming. We've implemented this approach in the past and
  # decided against it here:
  # 1. Performance. As the CLI suite grows, you have to load more and more
  # code, including dependencies that are installed by rubygems, etc. This gets
  # slow, and CLI apps need to be fast.
  # 2. You can workaround the above by having a convention mapping filename to
  # command name, but then you have to do a lot of work to list all of the
  # commands, which is actually a common thing to do.
  # 3. Other ways to mitigate the performance issue (loading deps lazily) have
  # their own complications and tradeoffs and don't fully solve the problem.
  # 4. It's not actually that much work to maintain the mapping.
  #
  # ## Adding new commands globally:
  #
  # A "singleton-ish" instance of this class is stored as Chef.commands_map.
  # You can configure a multiple commands at once in a block using
  # Chef.commands, like so:
  #
  #   Chef.commands do |c|
  #     # assigns `chef my-command` to the class ChefCLI::Command::MyCommand.
  #     # The "require path" is inferred to be "chef-cli/command/my_command"
  #     c.builtin("my-command", :MyCommand)
  #
  #     # Set the require path explicitly:
  #     c.builtin("weird-command", :WeirdoClass, require_path: "chef-cli/command/this_is_cray")
  #
  #
  #     # You can setup a chain of subcommand invoked like `chef parent-cmd child-cmd`,
  #     # including optional aliases.  An alias will only work if it exists on a
  #     # leaf node/command without subcommands.
  #     c.builtin("parent-cmd", :ParentCmd, subcommands: [
  #       c.builtin("child-cmd", :ChildCmd)
  #       c.builtin("child-cmd-2", :Child2Cmd, cmd_alias: "parent-child")
  #     ])
  #   end
  #
  #
  class CommandsMap
    NULL_ARG = Object.new

    CommandSpec = Struct.new(:name, :constant_name, :text, :require_path, :hidden, :subcommands, :parent)

    class CommandSpec

      def instantiate
        command_class.new(self)
      end

      def qualified_name
        @qualified_name ||= begin
            # Until we make the hidden root the real root, an extra step
            # to ensure the alias doesn't describe itself as "hidden-base target converge"
          parent_name = if parent.nil? || parent.qualified_name == "hidden-root"
                          ""
                        else
                          "#{parent.qualified_name} "
                        end
          "#{parent_name}#{name}"
        end
      end

      def command_class
        @command_class ||= begin
          require require_path
          # Definitely need a better API for constructing these commands and nested commands.
          # Should not need to put in parent class constant inside builtin_commands
          if constant_name.is_a? Array
            klass = ChefCLI::Command
            constant_name.each do |name|
              klass = klass.const_get(name)
            end
            klass
          else
            klass = ChefCLI::Command.const_get(constant_name)
          end
          # We store the banner at the class level (not instance) so we do not have to
          # require/load every command class to display the help output.
          klass.banner(make_banner)
          klass.usage(make_usage)
          klass
        end
      end

      def make_usage
        # TODO an OutputFormatter that understands "format_usage(command) might be better.
        usage = ChefCLI::Text.commands.base.usage
        usage_text_split = text.usage.split("\n")
        if usage_text_split.length == 1
          usage << text.usage
        else
          usage << "\n"

          usage_text_split.each do |t|
            usage << "  #{t}\n"
          end
        end
        usage
      end

      def make_banner
        text.description + "\n" + text.usage_full
      end

    end

    attr_reader :command_specs, :alias_specs

    def initialize
      @command_specs = {}
      @alias_specs = {}
    end

    def top_level(name, constant_name, text, require_path, hidden: false, subcommands: [])
      command_specs[name] = create(name, constant_name, text, require_path,
                                   hidden: hidden, subcommands: subcommands)
    end

    def create(name, constant_name, text, require_path, cmd_alias: "",
               hidden: false, subcommands: [])
      subcommandmap = Hash[subcommands.collect { |c| [c.name, c] } ]
      cmd_spec = CommandSpec.new(name, constant_name, text, require_path,
                                 hidden, subcommandmap)
      subcommandmap.each_value { |v| v.parent = cmd_spec }
      unless cmd_alias.empty?
        @alias_specs[cmd_alias] = cmd_spec
      end
      cmd_spec
    end

    # The user could be trying to invoke a subcommand - like `chef target converge`. In this case we want to
    # instantiate the converge command. We also remove any command names from the params so it can be
    # invoked correctly by the caller.
    #
    # This can also be an alias - if there is no matching command name,
    # check for a matching alias name.
    def instantiate(name, additional_params = [])
      cmd = command_specs[name] || alias_specs[name]
      additional_params.each_with_index do |possible_subcommand, i|
        subcommand = cmd.subcommands[possible_subcommand]
        if subcommand
          cmd = subcommand
        else
          additional_params = additional_params[i, additional_params.size]
          break
        end
      end
      [cmd.instantiate, additional_params]
    end

    def have_command_or_alias?(name)
      command_specs.key?(name) || alias_specs.key?(name)
    end

    def command_names(with_hidden = false)
      return command_specs.keys if with_hidden

      command_specs.select { |k, v| !v.hidden }.keys
    end

    private

    def null?(argument)
      argument.equal?(NULL_ARG)
    end
  end

  def self.commands_map
    @commands_map ||= CommandsMap.new
  end

  def self.commands
    yield commands_map
  end
end
