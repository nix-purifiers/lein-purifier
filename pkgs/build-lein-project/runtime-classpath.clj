;; SPDX-License-Identifier: MIT
(ns leiningen.purifier-runtime-classpath
  (:require [clojure.string :as str]
            [leiningen.core.classpath :as classpath]
            [leiningen.core.project :as project]))

(defn purifier-runtime-classpath [model]
  ;; Development profiles may configure the repository mirrors used by the
  ;; lock. Preserve that resolution context while excluding their dependencies.
  (let [runtime (merge (project/unmerge-profiles model [:dev :provided])
                       (select-keys model [:mirrors :repositories]))]
    (println (str/join java.io.File/pathSeparator (classpath/get-classpath runtime)))))

(in-ns 'user)
