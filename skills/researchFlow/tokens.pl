#!/usr/bin/env perl
# Считает расход токенов исследования researchFlow по транскриптам субагентов Claude Code и пишет отчёт.
# Запускается из research.sh: tokens.pl <основная-копия> <slug> <файл-отчёта> [начало]
# Начало это время старта исследования в UTC: записи раньше него не считаются, так диспетчер не тянет в расход прошлую работу сессии.
# Транскрипты не публичный формат: что не разобрано, пропускается, а не роняет поток.
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));
use File::Basename qw(dirname);
use File::Glob qw(bsd_glob);
use JSON::PP qw(decode_json);

my ($root, $slug, $out_path, $since) = @ARGV;
die "нужны основная копия, slug и файл отчёта\n" unless defined $out_path;
utf8::decode(my $root_text = $root);
utf8::decode(my $out_text = $out_path);

# Доллары за миллион токенов. Токены в отчёте точные, цена считается по этой таблице.
# У Haiku 5.5 промпт длиннее long токенов идёт по карте в long_x раз дороже.
my %RATES = (
  'claude-opus-5-5'   => { in => 4,   out => 20,  read => 0.2,  w5m => 5,     w1h => 8 },
  'claude-sonnet-5-5' => { in => 2,   out => 10,  read => 0.2,  w5m => 2.5,   w1h => 4 },
  'claude-haiku-5-5'  => { in => 0.1, out => 0.5, read => 0.01, w5m => 0.125, w1h => 0.2, long => 100_000, long_x => 5 },
);
my @FIELDS = qw(input write read output);
my %ROLES = (постановщик => 'постановщик', автор => 'автор гипотез', проверяющий => 'проверяющий', критик => 'критик',
             сравнивающий => 'сравнивающий', postanovshchik => 'постановщик', author => 'автор гипотез',
             checker => 'проверяющий', critic => 'критик', comparator => 'сравнивающий');

sub tokens_of {
  my ($usage) = @_;
  return (
    input  => $usage->{input_tokens} // 0,
    write  => $usage->{cache_creation_input_tokens} // 0,
    read   => $usage->{cache_read_input_tokens} // 0,
    output => $usage->{output_tokens} // 0,
  );
}

# Неизвестная модель даёт undef: цену нельзя молча считать нулём.
sub price {
  my ($model, $usage) = @_;
  (my $id = $model // '') =~ s/\[.*//;
  my $rate = $RATES{$id} or return undef;
  my %t = tokens_of($usage);
  my $x = 1;
  $x = $rate->{long_x} if $rate->{long} && $t{input} + $t{write} + $t{read} > $rate->{long};
  my $w1h = $usage->{cache_creation}{ephemeral_1h_input_tokens} // 0;
  my $w5m = $t{write} - $w1h;
  return $x * ($t{input} * $rate->{in} + $w5m * $rate->{w5m} + $w1h * $rate->{w1h}
    + $t{read} * $rate->{read} + $t{output} * $rate->{out}) / 1e6;
}

# Первое сообщение агента: передача диспетчера. Из неё берётся принадлежность исследованию.
sub prompt_text {
  my ($entry) = @_;
  my $content = $entry->{message}{content} // '';
  return $content unless ref $content eq 'ARRAY';
  return join ' ', map { ref $_ eq 'HASH' ? $_->{text} // '' : '' } @$content;
}

sub read_entries {
  my ($file) = @_;
  open my $fh, '<:raw', $file or return;
  my @entries;
  while (my $line = <$fh>) {
    # Идущая сессия может оставить недописанную строку.
    my $entry = eval { decode_json($line) } or next;
    next unless ref $entry eq 'HASH';
    next if $since && ($entry->{timestamp} // '') lt $since;
    push @entries, $entry;
  }
  return @entries;
}

# Один ответ модели занимает несколько строк с одним message.id: считается последняя.
sub messages_of {
  my (@entries) = @_;
  my %messages;
  for my $entry (@entries) {
    my $message = $entry->{message};
    next unless ref $message eq 'HASH' && ref $message->{usage} eq 'HASH';
    $messages{ $message->{id} // "$message" } = $message;
  }
  return \%messages;
}

sub add_up {
  my ($row, $messages, $counted) = @_;
  for my $id (keys %$messages) {
    next if $counted && $counted->{$id}++;
    my $message = $messages->{$id};
    my %t = tokens_of($message->{usage});
    next unless grep { $_ } values %t;
    $row->{$_} += $t{$_} for @FIELDS;
    $row->{turns}++;
    my $cost = price($message->{model}, $message->{usage});
    if (defined $cost) { $row->{cost} += $cost } else { $row->{unknown} = 1 }
  }
}

sub merge_row {
  my ($total, $row) = @_;
  $total->{$_} += $row->{$_} // 0 for @FIELDS, qw(turns cost runs);
  $total->{unknown} ||= $row->{unknown};
}

sub num {
  my $n = reverse sprintf('%d', $_[0] // 0);
  $n =~ s/(\d{3})(?=\d)/$1 /g;
  return scalar reverse $n;
}

sub money {
  my ($row) = @_;
  return sprintf('%s$%.2f', $row->{unknown} ? '≥ ' : '', $row->{cost} // 0);
}

sub cells {
  my ($row) = @_;
  return join ' | ', $row->{runs} // 0, $row->{turns} // 0, (map { num($row->{$_}) } @FIELDS), money($row);
}

(my $project = $root_text) =~ s/[^A-Za-z0-9]/-/g;
my $config = $ENV{CLAUDE_CONFIG_DIR} // "$ENV{HOME}/.claude";
# Сессия в worktree приложения лежит в каталоге с тем же началом имени.
my @files = bsd_glob("$config/projects/$project*/*/subagents/agent-*.jsonl");

my $scratch = qr{\.agentflow/docs/research/\Q$slug\E(?![\w-])};
my (%rows, %sessions, %counted);
for my $file (sort @files) {
  my @entries = read_entries($file) or next;
  my ($first) = grep { ($_->{type} // '') eq 'user' } @entries;
  next unless $first;
  my $prompt = prompt_text($first);
  next unless $prompt =~ $scratch;

  (my $meta_file = $file) =~ s/\.jsonl$/.meta.json/;
  my $meta = {};
  if (open my $fh, '<:raw', $meta_file) {
    local $/;
    $meta = eval { decode_json(scalar <$fh>) } // {};
  }
  # Без определений агентов роль видна только из первых слов передачи.
  my ($word) = ($meta->{agentType} // '') =~ /^researchflow-(\w+)/;
  ($word) = $prompt =~ /^\s*Ты\s+(?:агент\s+роли\s+«|агент-)?(\p{L}+)/ unless $word;
  my $role = $ROLES{ $word // '' } or next;

  my %numbers = map { $_ => 1 } $prompt =~ m{$scratch/hypotheses/(\d+)-}g;
  my ($task) = keys %numbers == 1 ? keys %numbers : ('исследование');

  my $row = $rows{$task}{$role} //= {};
  $row->{runs}++;
  add_up($row, messages_of(@entries), \%counted);
  $sessions{ dirname(dirname($file)) } = 1;
}

unless (%rows) {
  print "нет данных\n";
  exit 0;
}

my (%total, $body);
for my $task (sort { ($a eq 'исследование' ? -1 : $a) <=> ($b eq 'исследование' ? -1 : $b) } do { no warnings; keys %rows }) {
  my %subtotal;
  for my $role (sort keys %{ $rows{$task} }) {
    my $row = $rows{$task}{$role};
    merge_row(\%subtotal, $row);
    $body .= "| $task | $role | " . cells($row) . " |\n";
  }
  $body .= "| $task | **всего** | " . cells(\%subtotal) . " |\n" if keys %{ $rows{$task} } > 1;
  merge_row(\%total, \%subtotal);
}

# Диспетчер не делится по исследованиям: его сессия могла вести и другую работу.
my %dispatcher;
for my $session (keys %sessions) {
  my $row = {};
  add_up($row, messages_of(read_entries("$session.jsonl")));
  merge_row(\%dispatcher, $row);
  $dispatcher{runs}++;
}

my %everything;
merge_row(\%everything, $_) for \%total, \%dispatcher;

open my $out, '>', $out_path or die "не записать $out_text: $!\n";
print $out "# Расход токенов: $slug\n\n",
  "| Гипотеза | Роль | Запусков | Ответов | Вход | Запись кэша | Чтение кэша | Выход | Цена |\n",
  "|---|---|---|---|---|---|---|---|---|\n",
  $body,
  "| итого | агенты | " . cells(\%total) . " |\n",
  "| итого | диспетчер с начала | " . cells(\%dispatcher) . " |\n",
  "| **итого** | **всего** | " . cells(\%everything) . " |\n\n",
  "Токены взяты из транскриптов, цена расчётная. «≥» значит, что у части ответов модель без цены в таблице.\n",
  "В строке «исследование» запуски без одной гипотезы: спека, пачки, идеи, сравнение и отчёт.\n",
  "В строке диспетчера его сессия с начала исследования; без времени старта вся сессия.\n";
close $out or die "не записать $out_text: $!\n";

printf "расход: около %s (агенты %s, диспетчер с начала, %s); вход %s, запись кэша %s, чтение кэша %s, выход %s; отчёт: %s\n",
  money(\%everything), money(\%total), money(\%dispatcher),
  num($everything{input}), num($everything{write}), num($everything{read}), num($everything{output}), $out_text;
