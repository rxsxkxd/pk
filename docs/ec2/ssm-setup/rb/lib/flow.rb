# frozen_string_literal: true

require_relative 'aws_cli'
require_relative 'cli'

# AWS の上の設定を変えるコマンドの共通の流れ（汎用の部品。Infrastructure 層）:
# 確かめて分けて表示する → 試行するかを確かめる → 1 台ずつ行う → 結果 → 後の確認（finish）。
# 各コマンドは「確かめる（Plan を作る）」と「行う（execute のブロック）」だけを書く。
# 終了コード: 0 = すべて済んだ・何もしなくてよい、1 = 失敗・対象外・後の確認の問題あり、2 = 入力・確認・前提の問題。
# 確かめるだけのコマンドは使わない。
module Flow
  # 行う台。label は表示の 1 行目、value はコマンドの側の記録
  Item = Struct.new(:id, :label, :value)

  # 確かめた結果。todo（Item）を行い、keep（何もしない）・excluded（対象外。理由つき）は表示の行
  class Plan
    attr_reader :title, :question, :todo, :keep, :excluded, :keep_title, :excluded_title, :done_word
    # 済んだ Item の一覧を受け取り、後の確認と案内を表示する（false を返すと終了コード 1）
    attr_accessor :finish

    # keep_title を nil にすると「何もしない」の区分を出さない。done_word は 1 台が済んだときの言葉
    def initialize(title:, question:, keep_title: '何もしない', excluded_title: '対象外', done_word: '完了')
      @title = title
      @question = question
      @keep_title = keep_title
      @excluded_title = excluded_title
      @done_word = done_word
      @todo = []
      @keep = []
      @excluded = []
    end

    # 表示する区分（[見出し, 行の一覧]）。行う台は別に表示する
    def other_groups
      [[keep_title, keep], [excluded_title, excluded]].select(&:first)
    end
  end

  module_function

  # 確かめる（ブロックで Plan を作る）。AWS CLI が失敗したら、表示して終了コード 2 で止める（何も変えていない）
  def plan
    yield
  rescue AwsCli::Error => e
    puts "止めた: #{e.message.strip}"
    exit 2
  end

  # 表示 → 確認 → 1 台ずつ行う（ブロックは済んだときの説明を返す。AwsCli::Error で失敗）→ 結果。終了コードを返す
  def execute(plan, heading:, check_only: false, assume_yes: false, &apply)
    show(plan)
    return 0 if check_only
    return nothing_to_do(plan) if plan.todo.empty?

    code = ask_go(plan, assume_yes)
    return code if code

    done = run_all(plan, heading, &apply)
    print_summary(plan, done)
    problem?(plan, done, finish(plan, done)) ? 1 : 0
  end

  def show(plan)
    puts "\n== #{plan.title}（#{plan.todo.size} 台）"
    plan.todo.each { |item| puts "  #{item.label}" }
    plan.other_groups.each do |title, lines|
      puts "\n== #{title}（#{lines.size} 台）"
      lines.each { |line| puts "  #{line}" }
    end
  end

  def nothing_to_do(plan)
    puts "\n行う台がないので、終わる"
    plan.excluded.empty? ? 0 : 1
  end

  # 試行するかを確かめる。進めるなら nil、進めないなら終了コード
  def ask_go(plan, assume_yes)
    return nil if assume_yes

    answer = Cli.ask("\n上の #{plan.todo.size} 台に、#{plan.question}")
    return nil if answer

    puts answer.nil? ? '確認のための端末がない。確かめずに進めるなら --yes を付ける' : '中止した'
    answer.nil? ? 2 : 0
  end

  def run_all(plan, heading)
    puts "\n== #{heading}"
    plan.todo.each_with_index.select do |item, index|
      puts "  [#{index + 1}/#{plan.todo.size}] #{item.label}"
      run_one(plan) { yield item }
    end.map(&:first)
  end

  def run_one(plan)
    detail = yield
    puts detail ? "      #{plan.done_word}: #{detail}" : "      #{plan.done_word}"
    true
  rescue AwsCli::Error => e
    puts "      失敗: #{e.summary}"
    false
  end

  def print_summary(plan, done)
    counts = ["#{plan.done_word} #{done.size} 台", "失敗 #{plan.todo.size - done.size} 台"]
    counts << "何もしない #{plan.keep.size} 台" if plan.keep_title
    counts << "対象外 #{plan.excluded.size} 台"
    puts "\n== 結果: #{counts.join('、')}"
  end

  # 後の確認（済んだ台があるときだけ）。結果（false なら問題あり）
  def finish(plan, done)
    plan.finish.call(done) if plan.finish && !done.empty?
  end

  def problem?(plan, done, finished)
    done.size < plan.todo.size || !plan.excluded.empty? || finished == false
  end

  private_class_method :show, :nothing_to_do, :ask_go, :run_all, :run_one, :print_summary, :finish, :problem?
end
