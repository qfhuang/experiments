#lang racket
(provide
  )

(require
  "database.rkt"
  "interaction-model.rkt"
  "workspace-model.rkt"
  gregr-misc/cursor
  gregr-misc/dict
  gregr-misc/list
  gregr-misc/maybe
  gregr-misc/monad
  gregr-misc/record
  gregr-misc/sugar
  gregr-misc/ui
  )

(module+ test
  (require
    "syntax-abstract.rkt"
    gregr-misc/navigator
    rackunit
    ))

(record interaction-widget name)

(define (commands->keymap commands)
  (make-immutable-hash
    (forl
      (list char desc cmd) <- commands
      (cons char cmd))))

(define (workspace->focus-commands ws-name ws db)
  (maybe-fold '() (fn ((interaction-widget name))
                      (interaction->commands ws-name name db))
              (workspace->focus-widget ws)))

(def (db->workspace-commands-top name db)
  ; TODO: specialized commands based on workspace state
  ;ws = (:.* db 'workspaces name)
  cmd-table =
  `((#\q "pane close" ,wci-widget-close)
    (#\H "pane left" ,wci-widget-left)
    (#\L "pane right" ,wci-widget-right)
    (#\R "pane reverse" ,wci-widget-reverse))
  (forl
    (list char desc instr) <- cmd-table
    (list char desc (compose1 (curry workspace-command name) instr))))

(def (db->workspace-commands name db)
  ws = (:.* db 'workspaces name)
  ws-top-cmds = (db->workspace-commands-top name db)
  widget-cmds = (workspace->focus-commands name ws db)
  cmds->char-assoc = (lambda (cmds)
                       (forl
                         cmd <- cmds
                         (list char _ _) = cmd
                         (cons char cmd)))
  cmds-merge1 = (fn (cmds0 cmds1)
                  (list a0 a1) = (map cmds->char-assoc (list cmds0 cmds1))
                  a1 = (dict-subtract a1 a0)
                  (append* (map (curry map cdr) (list a0 a1))))
  (cmds-merge1 ws-top-cmds widget-cmds))

(define (event->workspace-command ws-name)
  (fn (db (event-keycount char count))
    cmds = (db->workspace-commands ws-name db)
    keymap = (commands->keymap cmds)
    (begin/with-monad maybe-monad
      cmd-new <- (dict-get keymap char)
      (pure (cmd-new count)))))

(define (interaction->commands ws-name name db)
  ; TODO: specialized commands based on interaction state
  (forl
    (list char desc instr) <-
    `((#\h "traverse left" ,ici-traverse-left)
      (#\j "traverse down" ,ici-traverse-down)
      (#\k "traverse up" ,ici-traverse-up)
      (#\l "traverse right" ,ici-traverse-right)
      (#\S "substitute completely" ,(lambda (_) (ici-substitute-complete)))
      (#\s "step" ,ici-step)
      (#\c "step completely" ,(lambda (_) (ici-step-complete)))
      (#\x "toggle-syntax" ,(lambda (_) (ici-toggle-syntax)))
      (#\u "undo" ,ici-undo))
    (list char desc
          (compose1 (curry interaction-command ws-name name) instr))))

(module+ test
  (require (submod "interaction-model.rkt" test-support))
  (define test-iaction-0 (list-ref test-iactions 0))
  (define test-iaction-1 (list-ref test-iactions 1))
  (define test-db-0
    (:=* database-empty (hash 'one workspace-empty) 'workspaces))
  (define test-widget-count 7)
  (define test-widgets (map interaction-widget (range test-widget-count)))
  (define test-db-1
    (:=* (:=* test-db-0 (workspace-new test-widgets 1) 'workspaces 'one)
         (:=* (list->index-dict (make-list test-widget-count test-iaction-0))
              test-iaction-1 1)
         'interactions)))

(module+ test
  (check-equal?
    (map list-init (db->workspace-commands 'one test-db-0))
    (map list-init (db->workspace-commands-top 'one test-db-0))
    )
  (check-equal?
    (list->string (map car (db->workspace-commands 'one test-db-1)))
    "qHLRhjklSscxu"
    ))

(module+ test
  (check-equal?
    (lets
      event->cmd = (event->workspace-command 'one)
      (list
        (event->cmd test-db-0 (event-keycount #\j 3))
        (event->cmd test-db-1 (event-keycount #\j 3))
        (event->cmd test-db-0 (event-keycount #\q 2))
        ))
    (list
      (nothing)
      (just (interaction-command 'one 1 (ici-traverse-down 3)))
      (just (workspace-command 'one (wci-widget-close 2)))
      )))

(module+ test
  (require (submod "workspace-model.rkt" test-support))
  (check-equal?
    (database-update (workspace-command 'one (wci-widget-right 2)) test-db-0)
    test-db-0)
  (void (forl
    ws <- test-workspaces
    path = (list 'workspaces 'one)
    db = (:= test-db-1 ws path)
    (forl
      instr <- test-instrs
      cmd = (workspace-command 'one instr)
      db = (database-update cmd db)
      (check-equal?
        (:. db path)
        (workspace-update instr ws)))))
  (void (forl
    ia <- test-iactions
    path = (list 'interactions 3)
    db = (:= test-db-1 ia path)
    (forl
      instr <- (list (ici-step-complete) (ici-traverse-down 1))
      cmd = (interaction-command 'one 3 instr)
      db = (database-update cmd db)
      (check-equal?
        (list (:.* db 'workspaces 'one 'notification) (:. db path))
        (interaction-update instr ia)))))
  )