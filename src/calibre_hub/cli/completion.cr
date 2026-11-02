module CalibreHub
  module Cli
    # Shell completion generated from the command table, for `hub` and
    # `calibre-hub cli`
    module Completion
      SERVER_COMMANDS = %w(serve scan install-triggers handler cli)

      def self.fish(progs : Array(String)) : String
        String.build do |s|
          s << "# fish completion for #{progs.join(", ")} (calibre-hub cli completion fish)\n"
          progs.each do |prog|
            # calibre-hub needs "cli" first; hub is the CLI itself
            base = prog == "hub" ? "" : "__fish_seen_subcommand_from cli; and "
            if prog == "hub"
              s << "complete -c hub -f\n"
            else
              s << "complete -c #{prog} -n '__fish_use_subcommand' -f -a '#{SERVER_COMMANDS.join(" ")}'\n"
              s << "complete -c #{prog} -n '__fish_seen_subcommand_from cli' -f\n"
            end
            names = COMMANDS.map(&.name).join(" ")
            COMMANDS.each do |c|
              s << "complete -c #{prog} -n '#{base}not __fish_seen_subcommand_from #{names}' -a #{c.name} -d #{quote(c.summary)}\n"
            end
            COMMANDS.each do |c|
              cond = "-n '#{base}__fish_seen_subcommand_from #{c.name}'"
              c.choices.try { |ch| s << "complete -c #{prog} #{cond} -a '#{ch.join(" ")}'\n" }
              s << "complete -c #{prog} #{cond} -F\n" if c.files
              c.all_flags.each do |f|
                s << "complete -c #{prog} #{cond} -l #{f.name}"
                f.short.try { |x| s << " -s " << x }
                if f.arg
                  if ch = f.choices
                    s << " -x -a '#{ch.join(" ")}'"
                  elsif f.file
                    s << " -r -F"
                  else
                    s << " -x"
                  end
                end
                s << " -d " << quote(f.help) << '\n'
              end
            end
          end
        end
      end

      def self.bash(progs : Array(String)) : String
        String.build do |s|
          s << "# bash completion for #{progs.join(", ")} (calibre-hub cli completion bash)\n"
          s << "_calibre_hub_cli() {\n"
          s << "  local start=$1 cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]} cmd= i\n"
          s << "  for ((i = start; i < COMP_CWORD; i++)); do\n"
          s << "    case ${COMP_WORDS[i]} in -*) ;; *) cmd=${COMP_WORDS[i]}; break ;; esac\n"
          s << "  done\n"
          s << "  if [[ -z $cmd ]]; then\n"
          s << "    COMPREPLY=($(compgen -W '#{COMMANDS.map(&.name).join(" ")}' -- \"$cur\")); return\n"
          s << "  fi\n"
          s << "  case \"$cmd:$prev\" in\n"
          COMMANDS.each do |c|
            c.all_flags.each do |f|
              next unless f.arg
              pats = ["#{c.name}:--#{f.name}"]
              f.short.try { |x| pats << "#{c.name}:-#{x}" }
              action = if ch = f.choices
                         "COMPREPLY=($(compgen -W '#{ch.join(" ")}' -- \"$cur\"))"
                       elsif f.file
                         "COMPREPLY=($(compgen -f -- \"$cur\"))"
                       else
                         "COMPREPLY=()"
                       end
              s << "    #{pats.join("|")}) #{action}; return ;;\n"
            end
          end
          s << "  esac\n"
          s << "  if [[ $cur == -* ]]; then\n"
          s << "    case $cmd in\n"
          COMMANDS.each do |c|
            flags = c.all_flags.flat_map { |f| ["--#{f.name}"] + (f.short ? ["-#{f.short}"] : [] of String) }
            s << "      #{c.name}) COMPREPLY=($(compgen -W '#{flags.join(" ")}' -- \"$cur\")) ;;\n"
          end
          s << "    esac\n"
          s << "    return\n"
          s << "  fi\n"
          s << "  case $cmd in\n"
          COMMANDS.each do |c|
            if ch = c.choices
              s << "    #{c.name}) COMPREPLY=($(compgen -W '#{ch.join(" ")}' -- \"$cur\")) ;;\n"
            elsif c.files
              s << "    #{c.name}) COMPREPLY=($(compgen -f -- \"$cur\")) ;;\n"
            end
          end
          s << "  esac\n"
          s << "}\n"
          progs.each do |prog|
            if prog == "hub"
              s << "_calibre_hub_hub() { _calibre_hub_cli 1; }\n"
              s << "complete -F _calibre_hub_hub hub\n"
            else
              s << "_calibre_hub_main() {\n"
              s << "  if ((COMP_CWORD > 1)) && [[ ${COMP_WORDS[1]} == cli ]]; then _calibre_hub_cli 2; return; fi\n"
              s << "  ((COMP_CWORD == 1)) && COMPREPLY=($(compgen -W '#{SERVER_COMMANDS.join(" ")}' -- \"${COMP_WORDS[COMP_CWORD]}\"))\n"
              s << "}\n"
              s << "complete -o default -F _calibre_hub_main #{prog}\n"
            end
          end
        end
      end

      private def self.quote(text : String) : String
        "'" + text.gsub('\\', "\\\\").gsub('\'', "\\'") + "'"
      end
    end
  end
end
