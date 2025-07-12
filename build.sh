#!/usr/bin/env bash
#
# build.sh
#   參數化的 CMake build 腳本，
#   支援 --root、--name（可接多個值）、--mode 五種選項：
#     --root <project_root>    專案根目錄，預設 $HOME/project/traccc
#     --name <dir1> [<dir2> ...]  build 目錄名稱，可以一次指定多個
#                              （例如 --name buildA buildB buildC）
#     --mode <build|run|clean|nsys|nsys-log|run-stat>
#                             執行模式，預設 build
#     --num <number>           僅在 run-stat 模式下生效，指定要跑多少次 run
#
#   模式說明：
#     build      : 執行 CMake configure & build，然後自動 run 每個範例可執行檔。
#     run        : 只執行每個範例可執行檔，不做 configure/build。
#                  若同時指定多個 --name，則會擷取每次輸出中 “Event processing … ms/event” 的值，
#                  並在跑完所有目錄後一次列出所有值（不計算平均/變異）。
#     clean      : 只刪除指定的 build 目錄，不做其他事。
#     nsys       : 執行 nsys profile → 然後刪除 report1.nsys-rep（不保留）。
#     nsys-log   : 執行 nsys profile → 保留 report1.nsys-rep（不刪除）。
#     run-stat   : 重複執行 run 模式指定次數（--num <次數>），蒐集每次輸出中 “Event processing … ms/event” 的值，
#                  並在全部迭代結束後計算平均值與變異數，同時印出所有擷取到的值與實際採樣數量。
#

set -euo pipefail

###############################################################################
# 參數預設值
###############################################################################
PROJECT_ROOT="$HOME/project/traccc"
# 將 BUILD_DIR_NAMES 改成陣列，預設只有一個 "build"
BUILD_DIR_NAMES=("build")
MODE="run"      # 可選 build / run / clean / nsys / nsys-log / run-stat
NUM=1           # 僅在 run-stat 模式下有效，代表要跑幾次；預設 1 次
DATASET="10muon_10GeV"  # 預設資料集名稱，用於 --input-directory=odd/geant4_${DATASET}/
PLAT="cuda"    # 平台選項：cuda 或 cpu，預設 cuda

# nsys 報告檔（.nsys-rep）的預設位置
REPORT_BASE="$PROJECT_ROOT/report1"
REPORT_REP="$REPORT_BASE.nsys-rep"
SQLITE_REP="$REPORT_BASE.sqlite"
QDSTRM_REP="$REPORT_BASE.qdstrm"

###############################################################################
# 使用說明
###############################################################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [--root <project_root>] [--name <dir1> [<dir2> ...]] [--mode <build|run|clean|nsys|nsys-log|run-stat>] [--num <number>] [--help]

  --root <project_root>        專案根目錄，預設 ($HOME/project/traccc)。
  --name <dir1> [<dir2> ...]    build 資料夾名稱，可一次指定多個，預設 (build)。
  --mode <build|run|clean|nsys|nsys-log|run-stat|test>  執行模式，預設 (build)：
      build      : 執行 CMake configure & build，然後自動 run 每個範例可執行檔。
      run        : 只執行每個範例可執行檔，不做 configure/build。
                   若同時指定多個 --name，則會擷取每次輸出中 “Event processing … ms/event” 的值，並在跑完所有目錄後一次列出所有值（不計算平均/變異）。
      clean      : 只刪除指定的 build 目錄，不做其他事。
      nsys       : 以 nsys profile 包裹 run，執行完後刪掉 report1.nsys-rep（不保留）。
      nsys-log   : 以 nsys profile 包裹 run，執行完後保留 report1.nsys-rep（不刪除）。
      run-stat   : 重複執行 run 模式指定次數 (--num <次數>)，蒐集每次 “Event processing … ms/event” 的值，並計算平均與變異數，同時印出所有擷取到的值與實際筆數。
      test       : 僅跑每個指定 build 目錄下的 traccc_test_cuda 可執行檔。

  --num <number>               僅在 run-stat 模式下生效，要跑幾次 run。若未指定，預設為 1。
  --dataset <name>             指定要使用的 dataset（會替換掉 “10muon_10GeV”），預設 (10muon_10GeV)。
  --plat <cuda|cpu>            指定要編譯的平台，預設 (cuda)；若為 cpu，會改成 --preset host-fp32，並移除 CUDA 相關設定。
  --help                       顯示此說明並退出。

範例：
  # 預設走 build 模式（先 configure + build，然後再 run）
  ./build.sh

  # 指定 build 資料夾叫 A，用 build 模式
  ./build.sh --name A

  # 一次指定多個 build 目錄 A 和 B
  ./build.sh --name A B C

  # 指定 project root 並只做 run（對所有指定的 name）
  ./build.sh --root /path/to/traccc --name A B --mode run

  # 只刪除 /path/to/traccc/output_build 和 /path/to/traccc/output_test 這兩個資料夾
  ./build.sh --root /path/to/traccc --name output_build output_test --mode clean

  # 以 nsys profile 執行，可產生 report1.nsys-rep，執行完後刪掉該報告
  ./build.sh --mode nsys

  # 以 nsys profile 執行，可產生 report1.nsys-rep，但保留該報告
  ./build.sh --mode nsys-log

  # 以 run-stat 模式跑 5 次 run，蒐集 Event processing ms/event，最後印出平均與變異數，並展示所有擷取到的值與實際筆數
  ./build.sh --mode run-stat --num 5
EOF
  exit 1
}

###############################################################################
# 解析參數
###############################################################################
# 清空原先的陣列（預設會先有一個 "build"）
BUILD_DIR_NAMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --dataset)
      DATASET="$2"
      shift 2
      ;;
    --plat)  
      if [[ "$2" == "cuda" || "$2" == "cpu" || "$2" == "cpu-data" ]]; then  
        PLAT="$2"  
      else  
        echo "Error: --plat 只接受 cuda、cpu 或 cpu-data。" >&2  
        usage  
      fi  
      shift 2  
      ;;
    --name)
      shift
      # 只要接下來的引數不是另一個 "--xxx" 或者已經用完，就當作名稱加入陣列
      BUILD_DIR_NAMES=()
      while [[ $# -gt 0 && "$1" != --* ]]; do
        BUILD_DIR_NAMES+=("$1")
        shift
      done
      # 如果使用者只寫了 --name 但後面沒給東西，就報錯
      if [[ ${#BUILD_DIR_NAMES[@]} -eq 0 ]]; then
        echo "Error: --name 後面至少要跟一個目錄名稱。" >&2
        usage
      fi
      ;;
    --mode)
      case "$2" in
        build|run|clean|nsys|nsys-log|run-stat|test)
          MODE="$2"
          ;;
        *)
          echo "Error: --mode 只接受 build、run、clean、nsys、nsys-log 或 run-stat。" >&2
          usage
          ;;
      esac
      shift 2
      ;;
    --num)
      if [[ "$2" =~ ^[0-9]+$ ]]; then
        NUM="$2"
      else
        echo "Error: --num 後面必須是正整數。" >&2
        usage
      fi
      shift 2
      ;;
    --help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# 如果使用者從來沒給過 --name，就設定預設值
if [[ ${#BUILD_DIR_NAMES[@]} -eq 0 ]]; then
  BUILD_DIR_NAMES=("build")
fi

# 如果使用者沒給 --dataset，就沿用預設
if [[ -z "${DATASET:-}" ]]; then
  DATASET="10muon_10GeV"
fi

# 如果使用者沒給 --plat，就沿用預設
if [[ -z "${PLAT:-}" ]]; then
  PLAT="cuda"
fi

# 如果是 run-stat 模式，但是使用者沒給 --num，則使用預設值 NUM=1；
if [[ "$MODE" == "run-stat" && -z "${NUM}" ]]; then
  echo "沒有指定 --num，將預設跑 1 次。"
  NUM=1
fi

###############################################################################
# 印出目前參數資訊
###############################################################################
echo "=============================="
echo "  Project root : $PROJECT_ROOT"
echo -n "  Build folders: "
printf "\"%s\" " "${BUILD_DIR_NAMES[@]}"
echo
echo "  Mode         : $MODE"
if [[ "$MODE" == "run-stat" ]]; then
  echo "  Num          : $NUM"
fi
echo "=============================="

###############################################################################
# 根據 MODE，執行動作
###############################################################################
# 如果 run 模式且有超過一個 BUILD_DIR_NAME，事先準備容器蒐集各目錄的 Event Processing ms/event
if [[ "$MODE" == "run" && ${#BUILD_DIR_NAMES[@]} -gt 1 ]]; then
  declare -a TIMES_LIST=()   # 用來存放 "目錄名稱:數值"
fi

# 如果 run-stat 模式且有超過一個 BUILD_DIR_NAME，就宣告 associative array
if [[ "$MODE" == "run-stat" && ${#BUILD_DIR_NAMES[@]} -gt 1 ]]; then
  declare -A ALL_TIMES_DICT  # key = BUILD_DIR_NAME, value = 多行 ms/event 字串
fi

for BUILD_DIR_NAME in "${BUILD_DIR_NAMES[@]}"; do
  BUILD_DIR="$PROJECT_ROOT/$BUILD_DIR_NAME"
  if [[ "$PLAT" == "cuda" ]]; then
    EXECUTABLE="$BUILD_DIR/bin/traccc_throughput_mt_cuda"
  else
    EXECUTABLE="$BUILD_DIR/bin/traccc_seq_example"
  fi

  case "$MODE" in

    clean)
      if [[ -d "$BUILD_DIR" ]]; then
        echo "[$BUILD_DIR_NAME] Cleaning: rm -rf $BUILD_DIR"
        rm -rf "$BUILD_DIR"
        echo "[$BUILD_DIR_NAME] Clean complete."
      else
        echo "[$BUILD_DIR_NAME] Note: Build folder 不存在，跳過 clean：$BUILD_DIR"
      fi
      ;;

    build)
      # 1) 建 build 資料夾（若不存在才建立）
      if [[ ! -d "$BUILD_DIR" ]]; then
        echo "[$BUILD_DIR_NAME] Creating directory: $BUILD_DIR"
        mkdir -p "$BUILD_DIR"
      else
        echo "[$BUILD_DIR_NAME] Build folder 已存在，直接使用：$BUILD_DIR"
      fi

      # 2) 執行 CMake configure
      echo "[$BUILD_DIR_NAME] Running cmake configure..."
      # 根據 PLAT 選擇 preset 及是否包含 CUDA 相關設定
      if [[ "$PLAT" == "cuda" ]]; then
        PRESET="--preset cuda-fp32"
        CUDA_FLAGS="-DTRACCC_BUILD_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75"
      else
        PRESET="--preset host-fp32"
        CUDA_FLAGS="-DTBB_DIR=$CONDA_PREFIX/lib/cmake/TBB"
      fi
      # 若平台為 cpu-data，build 時啟用 GRU data collection
      if [[ "$PLAT" == "cpu-data" ]]; then
        GRU_DATA_FLAG="-DTRACCC_ENABLE_GRU_DATA_COLLECTION=ON"
      else
        GRU_DATA_FLAG=""
      fi
      # added after root 
      cmake -S "$PROJECT_ROOT" -B "$BUILD_DIR" \
            $PRESET \
            $CUDA_FLAGS \
            $GRU_DATA_FLAG \
            -DTRACCC_BUILD_TESTING=ON \
            -DTRACCC_BUILD_EXAMPLES=ON \
            -DCMAKE_CXX_STANDARD=20 \
            -DTRACCC_USE_SYSTEM_GOOGLETEST=ON \
            -DTRACCC_USE_ROOT=ON 

      # 3) 執行 build
      echo "[$BUILD_DIR_NAME] Building with CMake..."
      cmake --build "$BUILD_DIR" -- -j"$(nproc)" 2>&1

      # 4) 執行範例
      if [[ -x "$EXECUTABLE" ]]; then
        echo "[$BUILD_DIR_NAME] Running example executable: $EXECUTABLE"
        if [[ "$PLAT" == "cuda" ]]; then
          "$EXECUTABLE" \
            --detector-file=geometries/odd/odd-detray_geometry_detray.json \
            --material-file=geometries/odd/odd-detray_material_detray.json \
            --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
            --use-detray-detector=on \
            --digitization-file=geometries/odd/odd-digi-geometric-config.json \
            --use-acts-geom-source=on \
            --input-directory=odd/geant4_${DATASET}/ \
            --input-events=10 \
            --processed-events=1000 \
            --threads=1
        else
          "$EXECUTABLE" \
            --detector-file=geometries/odd/odd-detray_geometry_detray.json \
            --material-file=geometries/odd/odd-detray_material_detray.json \
            --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
            --use-detray-detector=on \
            --digitization-file=geometries/odd/odd-digi-geometric-config.json \
            --use-acts-geom-source=on \
            --input-directory=odd/geant4_${DATASET}/ \
            --input-events=10
        fi
        echo "[$BUILD_DIR_NAME] Build+Run complete."
      else
        echo "[$BUILD_DIR_NAME] Warning: 找不到可執行檔 $EXECUTABLE，跳過執行。"
      fi
      ;;

    run)
      # 如果只有一個 BUILD_DIR_NAME，就沿用原本行為：只跑一次
      if [[ ${#BUILD_DIR_NAMES[@]} -eq 1 ]]; then
        if [[ -x "$EXECUTABLE" ]]; then
          echo "[$BUILD_DIR_NAME] Only running example executable: $EXECUTABLE"
          if [[ "$PLAT" == "cuda" ]]; then
            "$EXECUTABLE" \
              --detector-file=geometries/odd/odd-detray_geometry_detray.json \
              --material-file=geometries/odd/odd-detray_material_detray.json \
              --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
              --use-detray-detector=on \
              --digitization-file=geometries/odd/odd-digi-geometric-config.json \
              --use-acts-geom-source=on \
              --input-directory=odd/geant4_${DATASET}/ \
              --input-events=10 \
              --processed-events=1000 \
              --threads=1
          elif [[ "$PLAT" == "cpu-data" ]]; then
            "$EXECUTABLE" \
              --detector-file=geometries/odd/odd-detray_geometry_detray.json \
              --material-file=geometries/odd/odd-detray_material_detray.json \
              --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
              --use-detray-detector=on \
              --digitization-file=geometries/odd/odd-digi-geometric-config.json \
              --use-acts-geom-source=on \
              --input-directory=odd/geant4_${DATASET}/ \
              --input-events=100
          else
            "$EXECUTABLE" \
              --detector-file=geometries/odd/odd-detray_geometry_detray.json \
              --material-file=geometries/odd/odd-detray_material_detray.json \
              --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
              --use-detray-detector=on \
              --digitization-file=geometries/odd/odd-digi-geometric-config.json \
              --use-acts-geom-source=on \
              --input-directory=odd/geant4_${DATASET}/ \
              --input-events=10
          fi
          echo "[$BUILD_DIR_NAME] Run complete."
        else
          echo "[$BUILD_DIR_NAME] Error: 執行模式為 run，但找不到可執行檔：$EXECUTABLE" >&2
          echo "[$BUILD_DIR_NAME] 請先用 build 模式產生該可執行檔，或確認 build 目錄與名稱是否正確。" >&2
          exit 1
        fi

      # 如果指定了多個 BUILD_DIR_NAME，就把每個執行檔的 Event Processing ms/event 抓出來，最後一次性列出
      else
        if [[ -x "$EXECUTABLE" ]]; then
          echo "[$BUILD_DIR_NAME] [run] Running executable to extract Event Processing ms/event: $EXECUTABLE"
          if [[ "$PLAT" == "cuda" ]]; then
            OUTPUT="$("$EXECUTABLE" \
              --detector-file=geometries/odd/odd-detray_geometry_detray.json \
              --material-file=geometries/odd/odd-detray_material_detray.json \
              --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
              --use-detray-detector=on \
              --digitization-file=geometries/odd/odd-digi-geometric-config.json \
              --use-acts-geom-source=on \
              --input-directory=odd/geant4_${DATASET}/ \
              --input-events=10 \
              --processed-events=1000 \
              --threads=1 2>&1)"
          else
            OUTPUT="$("$EXECUTABLE" \
              --detector-file=geometries/odd/odd-detray_geometry_detray.json \
              --material-file=geometries/odd/odd-detray_material_detray.json \
              --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
              --use-detray-detector=on \
              --digitization-file=geometries/odd/odd-digi-geometric-config.json \
              --use-acts-geom-source=on \
              --input-directory=odd/geant4_${DATASET}/ \
              --input-events=10 2>&1)"
          fi
          echo "$OUTPUT"   # 仍然把完整輸出列出來

          # 從輸出中擷取最後一行 "Event processing ... ms/event" 前的數值
          TIME_VAL=$(echo "$OUTPUT" \
            | grep "Event processing" \
            | tail -n1 \
            | awk '{for(i=1;i<=NF;i++){ if($i=="ms/event,"){ print $(i-1) } }}')

          if [[ -z "$TIME_VAL" ]]; then
            echo "[$BUILD_DIR_NAME] [run] Warning: 無法從輸出中擷取 ms/event，請確認執行結果格式是否如預期。"
          else
            echo "[$BUILD_DIR_NAME] [run] Extracted ms/event: $TIME_VAL"
            # 加到全域陣列（帶上 BUILD_DIR_NAME 以資辨識）
            TIMES_LIST+=("$BUILD_DIR_NAME:$TIME_VAL")
          fi
        else
          echo "[$BUILD_DIR_NAME] Error: 執行模式為 run，但找不到可執行檔：$EXECUTABLE" >&2
          echo "[$BUILD_DIR_NAME] 請先用 build 模式產生該可執行檔，或確認 build 目錄與名稱是否正確。" >&2
          exit 1
        fi
      fi
      ;;

    nsys)
      # 以 nsys profile 執行 → 執行完後刪除 report1.nsys-rep（不保留）
      if [[ -x "$EXECUTABLE" ]]; then
        echo "[$BUILD_DIR_NAME] Profiling and running with nsys (then delete report): $EXECUTABLE"
        if [[ "$PLAT" == "cuda" ]]; then
          nsys profile --trace=nvtx,cuda --stats=true "$EXECUTABLE" \
            --detector-file=geometries/odd/odd-detray_geometry_detray.json \
            --material-file=geometries/odd/odd-detray_material_detray.json \
            --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
            --use-detray-detector=on \
            --digitization-file=geometries/odd/odd-digi-geometric-config.json \
            --use-acts-geom-source=on \
            --input-directory=odd/geant4_${DATASET}/ \
            --input-events=10 \
            --processed-events=1000 \
            --threads=1
        else
          nsys profile --stats=true "$EXECUTABLE" \
            --detector-file=geometries/odd/odd-detray_geometry_detray.json \
            --material-file=geometries/odd/odd-detray_material_detray.json \
            --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
            --use-detray-detector=on \
            --digitization-file=geometries/odd/odd-digi-geometric-config.json \
            --use-acts-geom-source=on \
            --input-directory=odd/geant4_${DATASET}/ \
            --input-events=10
        fi


        # 執行完畢後刪除剛剛產生的 .nsys-rep
        if [[ -f "$REPORT_REP" ]]; then
          echo "[$BUILD_DIR_NAME] Deleting generated report: $REPORT_REP"
          rm -f "$REPORT_REP"
        else
          echo "[$BUILD_DIR_NAME] No report found to delete at: $REPORT_REP"
        fi
        if [[ -f "$SQLITE_REP" ]]; then
          echo "[$BUILD_DIR_NAME] Deleting generated report: $SQLITE_REP"
          rm -f "$SQLITE_REP"
        else
          echo "[$BUILD_DIR_NAME] No report found to delete at: $SQLITE_REP"
        fi
        if [[ -f "$QDSTRM_REP" ]]; then
          echo "[$BUILD_DIR_NAME] Deleting generated report: $QDSTRM_REP"
          rm -f "$QDSTRM_REP"
        else
          echo "[$BUILD_DIR_NAME] No report found to delete at: $QDSTRM_REP"
        fi

        echo "[$BUILD_DIR_NAME] nsys mode complete (report deleted)."
      else
        echo "[$BUILD_DIR_NAME] Error: 執行模式為 nsys，但找不到可執行檔：$EXECUTABLE" >&2
        echo "[$BUILD_DIR_NAME] 請先用 build 模式產生該可執行檔，或確認 build 目錄與名稱是否正確。" >&2
        exit 1
      fi
      ;;

    nsys-log)
      # 以 nsys profile 執行 → 執行完後保留 report1.nsys-rep（不刪除）
      if [[ -x "$EXECUTABLE" ]]; then
        echo "[$BUILD_DIR_NAME] Profiling and running with nsys (keep report): $EXECUTABLE"
        if [[ "$PLAT" == "cuda" ]]; then
          nsys profile --trace=nvtx,cuda --stats=true "$EXECUTABLE" \
            --detector-file=geometries/odd/odd-detray_geometry_detray.json \
            --material-file=geometries/odd/odd-detray_material_detray.json \
            --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
            --use-detray-detector=on \
            --digitization-file=geometries/odd/odd-digi-geometric-config.json \
            --use-acts-geom-source=on \
            --input-directory=odd/geant4_${DATASET}/ \
            --input-events=10 \
            --processed-events=1000 \
            --threads=1
        else
          nsys profile --stats=true "$EXECUTABLE" \
            --detector-file=geometries/odd/odd-detray_geometry_detray.json \
            --material-file=geometries/odd/odd-detray_material_detray.json \
            --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
            --use-detray-detector=on \
            --digitization-file=geometries/odd/odd-digi-geometric-config.json \
            --use-acts-geom-source=on \
            --input-directory=odd/geant4_${DATASET}/ \
            --input-events=10
        fi

        echo "[$BUILD_DIR_NAME] nsys-log mode complete (report retained at: $REPORT_REP)."
        echo "[$BUILD_DIR_NAME] nsys-log mode complete (report retained at: $SQLITE_REP)."
      else
        echo "[$BUILD_DIR_NAME] Error: 執行模式為 nsys-log，但找不到可執行檔：$EXECUTABLE" >&2
        echo "[$BUILD_DIR_NAME] 請先用 build 模式產生該可執行檔，或確認 build 目錄與名稱是否正確。" >&2
        exit 1
      fi
      ;;

    run-stat)
      # 重複執行 run 模式 NUM 次，蒐集每次輸出中 “Event processing … ms/event” 的值
      if [[ ! -x "$EXECUTABLE" ]]; then
        echo "[$BUILD_DIR_NAME] Error: 執行模式為 run-stat，但找不到可執行檔：$EXECUTABLE" >&2
        echo "[$BUILD_DIR_NAME] 請先用 build 模式產生該可執行檔，或確認 build 目錄與名稱是否正確。" >&2
        exit 1
      fi

      echo "[$BUILD_DIR_NAME] Entering run-stat mode: will run ${EXECUTABLE} ${NUM} times"
      # 暫存該目錄每次跑出的 ms/event（多行字串）
      TIMES_LIST_THIS_DIR=""

      for (( i=1; i<=NUM; i++ )); do
        echo "[$BUILD_DIR_NAME] [run-stat] Iteration $i of $NUM"
        if [[ "$PLAT" == "cuda" ]]; then
          OUTPUT="$("$EXECUTABLE" \
            --detector-file=geometries/odd/odd-detray_geometry_detray.json \
            --material-file=geometries/odd/odd-detray_material_detray.json \
            --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
            --use-detray-detector=on \
            --digitization-file=geometries/odd/odd-digi-geometric-config.json \
            --use-acts-geom-source=on \
            --input-directory=odd/geant4_${DATASET}/ \
            --input-events=10 \
            --processed-events=1000 \
            --threads=1 2>&1)"
        else
          OUTPUT="$("$EXECUTABLE" \
            --detector-file=geometries/odd/odd-detray_geometry_detray.json \
            --material-file=geometries/odd/odd-detray_material_detray.json \
            --grid-file=geometries/odd/odd-detray_surface_grids_detray.json \
            --use-detray-detector=on \
            --digitization-file=geometries/odd/odd-digi-geometric-config.json \
            --use-acts-geom-source=on \
            --input-directory=odd/geant4_${DATASET}/ \
            --input-events=10 2>&1)"
        fi
        echo "$OUTPUT"

        TIME_VAL=$(echo "$OUTPUT" \
          | grep "Event processing" \
          | tail -n1 \
          | awk '{for(i=1;i<=NF;i++){ if($i=="ms/event,"){ print $(i-1) } }}')
        if [[ -z "$TIME_VAL" ]]; then
          echo "[$BUILD_DIR_NAME] [run-stat] Warning: 無法從輸出中擷取 ms/event，請確認執行結果格式是否如預期。"
        else
          echo "[$BUILD_DIR_NAME] [run-stat] Extracted ms/event: $TIME_VAL"
          TIMES_LIST_THIS_DIR+="$TIME_VAL"$'\n'
        fi

        # 在非最後一次時，等待 5 秒再執行下一次
        if (( i < NUM )); then
          echo "[$BUILD_DIR_NAME] [run-stat] Waiting 5 seconds before next iteration…"
          sleep 5
        fi

      done

      if [[ ${#BUILD_DIR_NAMES[@]} -gt 1 ]]; then
        # 多目錄情況：將整個多行字串存進 ALL_TIMES_DICT
        ALL_TIMES_DICT["$BUILD_DIR_NAME"]="$TIMES_LIST_THIS_DIR"
      else
        # 單一目錄情況：直接顯示該目錄的所有 ms/event、筆數、平均與變異
        echo "[$BUILD_DIR_NAME] [run-stat] All extracted ms/event values:"
        echo -e "$TIMES_LIST_THIS_DIR" | awk 'NF>0 { printf "  [%s] [run-stat] Value: %f ms/event\n", "'"$BUILD_DIR_NAME"'", $1 }'
        COUNT=$(echo -e "$TIMES_LIST_THIS_DIR" | awk 'NF>0 {c++} END {print c+0}')
        echo "[$BUILD_DIR_NAME] [run-stat] Number of successfully extracted values: $COUNT"

        echo -e "$TIMES_LIST_THIS_DIR" \
          | awk '
            NF>0 {
              sum += $1;
              sumsq += ($1)^2;
              n++;
            }
            END {
              if (n > 0) {
                mean = sum / n;
                var = sumsq / n - mean^2;
                printf "[%s] [run-stat] Average (ms/event) : %.6f\n", "'"$BUILD_DIR_NAME"'", mean;
                printf "[%s] [run-stat] Variance (ms/event): %.6f\n", "'"$BUILD_DIR_NAME"'", var;
              } else {
                printf "[%s] [run-stat] 沒有可用的資料點。\n", "'"$BUILD_DIR_NAME"'";
              }
            }
          '
      fi

      echo "[$BUILD_DIR_NAME] run-stat mode complete."
      ;;
      
    test)
      # 執行五個測試執行檔，擷取每個最後一次 "[==========]" 之後的資訊，然後回報
      BIN_DIR="$BUILD_DIR/bin"
      pushd "$BIN_DIR" > /dev/null || { echo "[$BUILD_DIR_NAME] Error: 無法進入 $BIN_DIR" >&2; exit 1; }
      TEST_EXES=(
        traccc_test_core
        traccc_test_examples
        traccc_test_cpu
        traccc_test_cuda
        traccc_test_io
      )
      declare -A TEST_RESULTS
      for exe in "${TEST_EXES[@]}"; do
        if [[ -x "./$exe" ]]; then
          echo "[$BUILD_DIR_NAME] Running test executable: $exe"
          # 關掉 gtest 的顏色輸出，避免 ANSI 色碼干擾
        # 強制 gtest 取消顏色，並把所有 ANSI escape code 移除
          # 加上 "|| true" 避免任意非零退碼讓 script 跳掉
          RAW_OUTPUT="$(GTEST_COLOR=never "./$exe" 2>&1 || true)"
        # 去掉像 "\x1B[32m" 這類的顏色碼
        OUTPUT="$(printf '%s' "$RAW_OUTPUT" | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
          # 反向讀取，擷取「最後一次」[==========] 開始到結尾的所有行
        # 反向擷取最後一次 [==========] 之後的所有行
        TEST_RESULTS["$exe"]="$(printf '%s\n' "$OUTPUT" \
          | tac \
          | sed -n '1,/\[==========\]/p' \
          | tac)"
        else
          echo "[$BUILD_DIR_NAME] Error: 找不到可執行檔：$exe" >&2
          TEST_RESULTS["$exe"]="Error: 找不到可執行檔"
        fi
      done
      # 一次把所有 executables 的測試摘要都印出來
      echo "==============================================="
      for exe in "${TEST_EXES[@]}"; do
        echo "[$BUILD_DIR_NAME] Summary for $exe:"
        # 用 sed 上色：PASSED 綠 / FAILED 紅
        printf '%s\n' "${TEST_RESULTS[$exe]}" \
          | sed -E \
              -e 's/\[  PASSED  \]/\x1B[32m&\x1B[0m/g' \
              -e 's/\[  FAILED  \]/\x1B[31m&\x1B[0m/g'
        echo "---------------------------------------------"
      done
      popd > /dev/null
      # 回到專案根目錄
      cd "$PROJECT_ROOT"
      ;;
    *)
      echo "Internal error: 未知的模式 $MODE" >&2
      exit 1
      ;;
  esac

  # 如果是 run 模式且跑完了最後一個 BUILD_DIR_NAME，就一起輸出多目錄情況下的所有 Event Processing 值
  if [[ "$MODE" == "run" && ${#BUILD_DIR_NAMES[@]} -gt 1 && "$BUILD_DIR_NAME" == "${BUILD_DIR_NAMES[-1]}" ]]; then
    echo "==============================================="
    echo "All extracted Event Processing values (run mode, 多目錄):"
    for entry in "${TIMES_LIST[@]}"; do
      # entry 格式："目錄名稱:數值"
      DIR_NAME="${entry%%:*}"
      VAL="${entry#*:}"
      printf "  [%s] Value: %s ms/event\n" "$DIR_NAME" "$VAL"
    done
    echo "==============================================="
  fi

  echo "---------------------------------------------"
done

# 如果 run-stat 模式且多於一個 BUILD_DIR_NAME，就在最外層迴圈跑完後一次性列出所有目錄的所有 ms/event
if [[ "$MODE" == "run-stat" && ${#BUILD_DIR_NAMES[@]} -gt 1 ]]; then
  # 用來存每個目錄的平均值，後面算差用
  declare -a MEANS_LIST=()

  # 只印摘要
  for DIR_NAME in "${BUILD_DIR_NAMES[@]}"; do
    TIMES_LIST_THIS_DIR="${ALL_TIMES_DICT[$DIR_NAME]}"

    # 計算筆數
    COUNT=$(echo -e "$TIMES_LIST_THIS_DIR" | awk 'NF{c++}END{print c+0}')
    # 同時計算平均與 StdDev
    read MEAN STDDEV <<< $(echo -e "$TIMES_LIST_THIS_DIR" \
      | awk '
          NF {
            sum += $1;
            sumsq += ($1)^2;
            n++;
          }
          END {
            if (n>0) {
              mean = sum/n;
              std = sqrt(sumsq/n - mean^2);
              printf "%.6f %.6f", mean, std;
            } else {
              printf "0.000000 0.000000";
            }
          }
        ')

    MEANS_LIST+=("$MEAN")

    echo "  [Directory: $DIR_NAME]"
    echo
    echo "    Number of data points: $COUNT"
    echo "    Average (ms/event): $MEAN"
    echo "    StdDev (ms/event): $STDDEV"
    echo
  done
fi

exit 0
